//! typechecker_types.l — resolved type representation.
//! Mirrors compiler/src/Lyric.TypeChecker/Type.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
pub use Lyric.Symbols

// The identity types live in `Lyric.Symbols` (docs/70 §4.2) so the resolver
// can name them before the checker runs; the checker re-exports them for the
// packages that name a `SymbolId` through it.
// ─────────────────────────────────────────────────────────────────────────────
// §1. Primitive types.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union PrimType {
  case PtBool
  case PtByte
  case PtInt
  case PtLong
  case PtUInt
  case PtULong
  case PtNat
  case PtFloat
  case PtDouble
  case PtChar
  case PtString
  case PtUnit
  case PtNever
}

// The built-in `Task[T]` (docs/68 §3): the handle `spawn f(x)` returns, with
// `T` the callee's result.  It has no declaring symbol, so it takes a reserved
// id (interned ids start at 1) and never reaches `symTableTypeSymbolOf`,
// which keeps it out of every table that turns a checked type back into a
// source type: no backend knows a source spelling for it.
pub func builtinTaskTypeId(): SymbolId {
  SymbolId(id = -1)
}

// The built-in `buffer[T]` (D185, docs/67 §4.4): a contiguous, runtime-length
// sequence of `Plain` elements with value semantics.  Like `Task[T]` it has no
// declaring symbol, so it takes a reserved id and never reaches
// `symTableTypeSymbolOf`.
pub func builtinBufferTypeId(): SymbolId {
  SymbolId(id = -2)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Resolved type.
// ─────────────────────────────────────────────────────────────────────────────
/// Whether an array type's `sizeVar` names a value generic parameter.
pub func hasSizeVar(sv: in Option[Type]): Bool {
  match sv {
    case Some(_) -> true
    case None -> false
  }
}

/// The name of an array type's value generic length parameter, or "".
pub func sizeVarName(sv: in Option[Type]): String {
  match sv {
    case Some(t) -> match t { case TyParam(n, _) -> n; case _ -> "" }
    case None -> ""
  }
}

@stable(since = "0.1")
pub union Type {
  case TyPrim(pt: PrimType)
  case TyTuple(elems: List[Type])
  case TyNullable(inner: Type)
  case TyFunction(params: List[Type], ret: Type, isAsync: Bool)
  // `sizeVar` is the value generic parameter (a `TyParam` with its binder) that
  // is the length when `size` is `None` because the length is a parameter
  // (`array[N, T]` in a value-generic declaration), and `None` otherwise.
  // Substituting the parameter fills `size` (D169).
  case TyArray(size: Option[Int], element: Type, sizeVar: Option[Type])
  case TySlice(element: Type)
  /// `TyUser.name` is the declared name from the type environment
  /// (set by `resolveTypePath` from the matched `Symbol.name`).
  /// `renderType` prefers it over the `<#id>` fallback so diagnostics
  /// surface human-readable type names (#425 item 6).  Empty string
  /// means "name lookup unavailable" — keeps the `<#id>` fallback for
  /// callers that synthesise a `TyUser` outside the resolver.
  case TyUser(id: SymbolId, name: String, args: List[Type])
  /// A refined (range-constrained) view of an underlying numeric type,
  /// e.g. the inline form `Int range 0 ..= 9`.  `lo` / `hi` carry the
  /// integer-literal endpoints when they are statically extractable
  /// (`None` for a non-literal or absent endpoint, i.e. `MIN` / `MAX`).
  /// `hiInclusive` distinguishes `..=` (closed, `true`) from `..`
  /// (half-open, `false`).  Refinement is *transparent* to `typeEquiv`
  /// (it unwraps to `underlying`), so widening the union introduces no
  /// new equivalence false positives — the bounds are consulted only by
  /// dedicated checks (e.g. T0015 inline-literal range validation).
  /// Named distinct range subtypes (`type Age = Int range …`) resolve to
  /// `TyUser`, not `TyRefined`; carrying their bounds is Band-4 work.
  /// `source` is the refined type as written (`Int range 0 ..= 9`), from
  /// which a runtime range check reads its bounds and message (#8031).
  case TyRefined(underlying: Type, lo: Option[Long], hi: Option[Long], hiInclusive: Bool, source: TypeExpr)
  case TySelf
  // A value generic argument that is a known length: the `3` of
  // `FixedVec[Int, 3]` (D169).  It appears only as a `TyUser` argument, or
  // as what a value generic parameter is bound to.
  case TyLen(n: Int)
  // A rigid generic parameter: equal only to itself (docs/70 §5.1).  `owner`
  // is the qualified name of the declaration that binds it, empty where the
  // checker does not yet thread the binder through.
  case TyParam(name: String, owner: String)
  // An inference variable, alive only while one call or binding is solved.
  case TyInfer(id: Int)
  // A type the checker could not give.  `diag` names the diagnostic that
  // caused it (docs/70 §5.1): a `DiagId` whose `index` is the 1-based position
  // of that diagnostic in the checker's diagnostic list, or 0 for a `TyError`
  // built with no diagnostic (`tyErrorSilent`), which the I0001 gate counts.
  case TyError(diag: DiagId)
  case TyException
  // Strip any refinement layers, yielding the underlying representation
  // type.  Refinements are transparent for equivalence and most queries.
}

/// The diagnostic behind a `TyError`: `index` is its 1-based position in the
/// checker's diagnostic list, 0 for none.
pub record DiagId {
  index: Int
}

/// A `TyError` with no recorded diagnostic.  Every such construction is a site
/// the I0001 gate and the silent-`TyError` census can find by name.
pub func tyErrorSilent(): Type {
  TyError(diag = DiagId(index = 0))
}

/// A `TyError` caused by the diagnostic most recently added to `diags`.
pub func tyErrorFor(diags: in List[Diagnostic]): Type {
  TyError(diag = DiagId(index = diags.count))
}

/// A `TyError` for a member the host boundary does not describe: the bridge
/// could not read the host type (no reference pack, a type it cannot locate, an
/// overload set whose results differ), or the host type it returns has no
/// `extern type` in scope.  The value is deliberately unchecked (docs/70 5.3),
/// so it is not silent: `DiagId` index -1 marks it for the I0001 gate.
pub func tyErrorHost(): Type {
  TyError(diag = DiagId(index = -1))
}

/// A `TyError` for a value whose type mentions a generic parameter that the
/// checker erases on purpose (a pattern binding, a loop variable or a lambda
/// parameter inside a generic body, see `eraseTyParams`): the `where`-bound
/// operations that make such a value usable are not tracked yet.  Named like
/// `tyErrorHost`, so the I0001 gate does not count it and `rg tyErrorGeneric`
/// is the inventory of what typing generic bodies has left (`DiagId` index -2).
pub func tyErrorGeneric(): Type {
  TyError(diag = DiagId(index = -2))
}

/// A `TyError` for a member call no checker rule resolves although the
/// backends do: a dot-named function the checker cannot see (a package-private
/// `internal func` of another package of the same library).  Named, like
/// `tyErrorHost`, so the I0001 gate does not count it; `rg tyErrorUnresolved`
/// is the inventory (`DiagId` index -3).
pub func tyErrorUnresolved(): Type {
  TyError(diag = DiagId(index = -3))
}

/// A `TyError` for a type argument no argument has fixed yet: the open hole
/// (`List[<hole>]` from `newList()`).  A later use fixes it (`resolveOpenBindingSites`)
/// or `reportUnsolvedTypeArgs` reports T0224, so it never reaches the backends
/// untyped without a diagnostic.  Named, like `tyErrorHost`, so the I0001 gate
/// does not count the reads of it (`DiagId` index -4).
pub func tyErrorOpen(): Type {
  TyError(diag = DiagId(index = -4))
}

/// The `DiagId` index at and below which a `TyError` is a shared enum case
/// (`SymbolTable.sharedCaseOwners`): index `-1000 - k` names the owners at
/// position `k`.  Negative, so the I0001 gate does not count it.
pub val sharedCaseIndexBase: Int = -1000

/// True for a `TyError` the checker leaves unchecked on purpose and says so
/// (`tyErrorHost`, `tyErrorGeneric`, `tyErrorUnresolved`, `tyErrorOpen`: a negative `DiagId`),
/// which the I0001 gate does not count.
pub func isNamedUncheckedTyError(t: in Type): Bool {
  match t {
    case TyError(d) -> d.index < 0
    case _ -> false
  }
}

/// True for a `TyError` that records no diagnostic.
pub func isSilentTyError(t: in Type): Bool {
  match t {
    case TyError(d) -> d.index == 0
    case _ -> false
  }
}

pub func unrefine(t: in Type): Type {
  match t {
    case TyRefined(u, _, _, _, _) -> unrefine(u)
    case _ -> t
  }
}

// `Task[result]`.
pub func taskType(result: in Type): Type {
  val targs: List[Type] = newList()
  targs.add(result)
  TyUser(id = builtinTaskTypeId(), name = "Task", args = targs)
}

// `buffer[element]`.
pub func bufferType(element: in Type): Type {
  val targs: List[Type] = newList()
  targs.add(element)
  TyUser(id = builtinBufferTypeId(), name = "buffer", args = targs)
}

// The element type `T` of a `buffer[T]`; None for any other type.
pub func bufferElementType(t: in Type): Option[Type] {
  match unrefine(t) {
    case TyUser(id, _, args) -> if symbolIdEq(id, builtinBufferTypeId()) and args.count == 1 {
      Some(value = args[0])
    } else {
      None
    }
    case _ -> None
  }
}

pub func isBufferType(t: in Type): Bool {
  match bufferElementType(t) {
    case Some(_) -> true
    case None -> false
  }
}

// The result type `R` of a `Task[R]`; None for any other type.
pub func taskResultType(t: in Type): Option[Type] {
  match unrefine(t) {
    case TyUser(id, _, args) -> if symbolIdEq(id, builtinTaskTypeId()) and args.count == 1 {
      Some(value = args[0])
    } else {
      None
    }
    case _ -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. PrimType helpers.
// ─────────────────────────────────────────────────────────────────────────────
pub func primName(pt: in PrimType): String {
  match pt {
    case PtBool -> "Bool"
    case PtByte -> "Byte"
    case PtInt -> "Int"
    case PtLong -> "Long"
    case PtUInt -> "UInt"
    case PtULong -> "ULong"
    case PtNat -> "Nat"
    case PtFloat -> "Float"
    case PtDouble -> "Double"
    case PtChar -> "Char"
    case PtString -> "String"
    case PtUnit -> "Unit"
    case PtNever -> "Never"
  }
}

pub func primFromString(s: in String): Option[PrimType] {
  if s == "Bool" {
    return Some(value = PtBool)
  }
  if s == "Byte" {
    return Some(value = PtByte)
  }
  if s == "Int" {
    return Some(value = PtInt)
  }
  if s == "Long" {
    return Some(value = PtLong)
  }
  if s == "UInt" {
    return Some(value = PtUInt)
  }
  if s == "ULong" {
    return Some(value = PtULong)
  }
  if s == "Nat" {
    return Some(value = PtNat)
  }
  if s == "Float" {
    return Some(value = PtFloat)
  }
  if s == "Double" {
    return Some(value = PtDouble)
  }
  if s == "Char" {
    return Some(value = PtChar)
  }
  if s == "String" {
    return Some(value = PtString)
  }
  if s == "Unit" {
    return Some(value = PtUnit)
  }
  if s == "Never" {
    return Some(value = PtNever)
  }
  None
}

func primEq(a: in PrimType, b: in PrimType): Bool {
  match a {
    case PtBool -> match b { case PtBool -> true; case _ -> false }
    case PtByte -> match b { case PtByte -> true; case _ -> false }
    case PtInt -> match b { case PtInt -> true; case _ -> false }
    case PtLong -> match b { case PtLong -> true; case _ -> false }
    case PtUInt -> match b { case PtUInt -> true; case _ -> false }
    case PtULong -> match b { case PtULong -> true; case _ -> false }
    case PtNat -> match b { case PtNat -> true; case _ -> false }
    case PtFloat -> match b { case PtFloat -> true; case _ -> false }
    case PtDouble -> match b { case PtDouble -> true; case _ -> false }
    case PtChar -> match b { case PtChar -> true; case _ -> false }
    case PtString -> match b { case PtString -> true; case _ -> false }
    case PtUnit -> match b { case PtUnit -> true; case _ -> false }
    case PtNever -> match b { case PtNever -> true; case _ -> false }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Type equivalence.
// ─────────────────────────────────────────────────────────────────────────────
/// Two parameters of the same name are the same parameter when they have the
/// same binder.  Every parameter has a binder; an empty owner is an internal
/// error (I0001, `gctxPushOwned`), so it matches only another empty owner.
pub func tyParamOwnersMatch(a: in String, b: in String): Bool {
  a == b
}

pub func typeEquiv(a: in Type, b: in Type): Bool {
  // Refinements are transparent: a refined type is equivalent to its
  // underlying representation (and vice versa).  Unwrap both sides first
  // so the rest of the comparison never has to know about TyRefined.
  val ua = unrefine(a)
  val ub = unrefine(b)
  match ua {
    case TyError(_) -> true
    case TyInfer(_) -> true
    case TyParam(na, oa) -> match ub {
      case TyError(_) -> true
      case TyInfer(_) -> true
      case TyParam(nb, ob) -> na == nb and tyParamOwnersMatch(oa, ob)
      case _ -> false
    }
    case _ -> match ub {
      case TyError(_) -> true
      case TyInfer(_) -> true
      case TyParam(_, _) -> false
      case _ -> typeEquivCore(ua, ub)
    }
  }
}

func typeEquivCore(a: in Type, b: in Type): Bool {
  match a {
    case TyError(_) -> true
    case TyParam(na, oa) -> match b {
      case TyParam(nb, ob) -> na == nb and tyParamOwnersMatch(oa, ob)
      case TyInfer(_) -> true
      case TyError(_) -> true
      case _ -> false
    }
    case TyInfer(_) -> true
    case TyPrim(pa) -> match b { case TyPrim(pb) -> primEq(pa, pb); case _ -> false }
    case TySelf -> match b { case TySelf -> true; case _ -> false }
    case TyLen(na) -> match b { case TyLen(nb) -> na == nb; case TyInfer(_) -> true; case _ -> false }
    case TyNullable(ia) -> match b { case TyNullable(ib) -> typeEquiv(ia, ib); case _ -> false }
    case TyTuple(xs) -> match b {
      case TyTuple(ys) -> if xs.count != ys.count { false } else { listTypesEquiv(xs, ys) }
      case _ -> false
    }
    case TyFunction(ps1, r1, asy1) -> match b {
      case TyFunction(ps2, r2, asy2) -> if asy1 != asy2 {
        false
      } else if ps1.count != ps2.count {
        false
      } else if not listTypesEquiv(ps1, ps2) {
        false
      } else {
        typeEquiv(r1, r2)
      }
      case _ -> false
    }
    case TyArray(sz1, e1, _) -> match b {
      case TyArray(sz2, e2, _) -> if not optIntEq(sz1, sz2) {
        false
      } else {
        typeEquiv(e1, e2)
      }
      case _ -> false
    }
    case TySlice(e1) -> match b { case TySlice(e2) -> typeEquiv(e1, e2); case _ -> false }
    case TyUser(id1, _, args1) -> match b {
      case TyUser(id2, _, args2) -> if not symbolIdEq(id1, id2) {
        false
      } else if args1.count != args2.count {
        false
      } else {
        listTypesEquiv(args1, args2)
      }
      case _ -> false
    }
    case TyException -> match b { case TyException -> true; case _ -> false }
    // `typeEquiv` strips refinements before dispatching here, so this arm
    // is only reached if `typeEquivCore` is called directly; unwrap to be
    // safe and keep the match exhaustive.
    case TyRefined(u, _, _, _, _) -> typeEquivCore(unrefine(u), unrefine(b))
  }
}

func listTypesEquiv(xs: in List[Type], ys: in List[Type]): Bool {
  var i = 0
  var ok = true
  while ok and i < xs.count {
    if not typeEquiv(xs[i], ys[i]) {
      ok = false
    }
    i = i + 1
  }
  ok
}

func optIntEq(a: in Option[Int], b: in Option[Int]): Bool {
  match a {
    case None -> match b { case None -> true; case Some(_) -> false }
    case Some(va) -> match b { case None -> false; case Some(vb) -> va == vb }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. Rendering.
// ─────────────────────────────────────────────────────────────────────────────
pub func renderType(t: in Type): String {
  match t {
    case TyError(_) -> "<error>"
    case TyException -> "Exception"
    case TySelf -> "Self"
    case TyLen(n) -> toString(n)
    case TyParam(nm, _) -> nm
    case TyInfer(i) -> "?" + toString(i)
    case TyPrim(pt) -> primName(pt)
    case TyNullable(inner) -> renderType(inner) + "?"
    case TyTuple(elems) -> "(" + joinTypes(elems, ", ") + ")"
    case TySlice(e) -> "slice[" + renderType(e) + "]"
    case TyArray(sz, e, _) -> match sz {
      case None -> "array[?, " + renderType(e) + "]"
      case Some(n) -> "array[" + toString(n) + ", " + renderType(e) + "]"
    }
    case TyFunction(ps, r, fAsync) -> {
      val prefix = if fAsync { "async " } else { "" }
      val pstr = "(" + joinTypes(ps, ", ") + ")"
      prefix + pstr + " -> " + renderType(r)
    }
    case TyRefined(u, lo, hi, inc, _) -> {
      // Render lo/hi conditionally so open-ended forms produce
      // `Int range 5 ..` / `Int range ..= 9` instead of the malformed
      // `Int range 5 ..= ` (trailing operator) or `Int range  ..= 9`
      // (leading double space) the old all-fields-always-emitted code
      // produced.
      val loStr = match lo { case None -> ""; case Some(v) -> toString(v) }
      val hiStr = match hi { case None -> ""; case Some(v) -> toString(v) }
      val opBare = if inc { "..=" } else { ".." }
      val left = if loStr.length > 0 { loStr + " " } else { "" }
      val right = if hiStr.length > 0 { " " + hiStr } else { "" }
      renderType(u) + " range " + left + opBare + right
    }
    case TyUser(uid, nm, args) -> {
      // #425 item 6: prefer the declared name carried in the type
      // environment over the `<#id>` synthetic fallback.  Empty
      // string means the constructor did not have name context;
      // fall back so diagnostics still produce something printable.
      val head = if nm.length > 0 { nm } else { "<#" + toString(uid.id) + ">" }
      if args.count == 0 {
        head
      } else {
        head + "[" + joinTypes(args, ", ") + "]"
      }
    }
  }
}

// #6418: the SOLE alias-aware type-name renderer. `alias` is fully
// transparent to the type system (checked structurally as `Type`, which
// carries no alias identity at all — see `docs/03-decision-log.md`
// D-progress-765), so this is display-only: it never affects pass/fail,
// only how a diagnostic spells a type name. Call sites reach it only where
// the ORIGINAL annotation `TypeExpr` (post `Lyric.TypeAliasResolve`, so
// `te.aliasName` is `Some` exactly when the user wrote an alias name here)
// and its resolved `Type` are already co-located in scope — threading
// `TypeExpr` provenance through the checker's internal signature registries
// (`ResolvedParam`/`ResolvedSignature`, which persist only `Type`) to reach
// every OTHER `renderType` call site (call-argument mismatches against a
// registered function signature, in particular) is out of scope here; see
// D-progress-765 for the covered vs. deferred diagnostic list. Every call
// site funnels through this one function rather than hand-building
// `"X (aka Y)"` per diagnostic, so the rendering shape stays uniform.
pub func renderTypeExpr(te: in TypeExpr, t: in Type): String {
  match te.aliasName {
    case Some(nm) -> nm + " (aka " + renderType(t) + ")"
    case None -> renderType(t)
  }
}

// #6467: `renderTypeExpr`'s `Option[TypeExpr]`-aware counterpart, for call
// sites (like `checkStatement`'s `returnTyExpr` thread) that carry the
// originating annotation only optionally — `None` when no source `TypeExpr`
// is co-located with `t` (e.g. a synthetic scope with no enclosing function).
pub func renderOptTypeExpr(teOpt: in Option[TypeExpr], t: in Type): String {
  match teOpt {
    case Some(te) -> renderTypeExpr(te, t)
    case None -> renderType(t)
  }
}

func joinTypes(ts: in List[Type], sep: in String): String {
  if ts.count == 0 {
    return ""
  }
  var s = renderType(ts[0])
  var i = 1
  while i < ts.count {
    s = s + sep + renderType(ts[i])
    i = i + 1
  }
  s
}
