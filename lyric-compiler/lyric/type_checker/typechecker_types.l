//! typechecker_types.l — resolved type representation.
//! Mirrors compiler/src/Lyric.TypeChecker/Type.fs.
package Lyric.TypeChecker

import Std.Core
import Std.Collections

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
  // ─────────────────────────────────────────────────────────────────────────────
  // §2. Type identifier (stable identity for user-defined types).
  // ─────────────────────────────────────────────────────────────────────────────
}

@stable(since = "0.1")
pub record TypeId {
  id: Int
}

pub func typeIdEq(a: in TypeId, b: in TypeId): Bool {
  a.id == b.id
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Resolved type.
// ─────────────────────────────────────────────────────────────────────────────
@stable(since = "0.1")
pub union Type {
  case TyPrim(pt: PrimType)
  case TyTuple(elems: List[Type])
  case TyNullable(inner: Type)
  case TyFunction(params: List[Type], ret: Type, isAsync: Bool)
  case TyArray(size: Option[Int], element: Type)
  case TySlice(element: Type)
  /// `TyUser.name` is the declared name from the type environment
  /// (set by `resolveTypePath` from the matched `Symbol.name`).
  /// `renderType` prefers it over the `<#id>` fallback so diagnostics
  /// surface human-readable type names (#425 item 6).  Empty string
  /// means "name lookup unavailable" — keeps the `<#id>` fallback for
  /// callers that synthesise a `TyUser` outside the resolver.
  case TyUser(id: TypeId, name: String, args: List[Type])
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
  case TyRefined(underlying: Type, lo: Option[Long], hi: Option[Long], hiInclusive: Bool)
  case TySelf
  case TyVar(name: String)
  case TyError
  case TyException
  // Strip any refinement layers, yielding the underlying representation
  // type.  Refinements are transparent for equivalence and most queries.
}

pub func unrefine(t: in Type): Type {
  match t {
    case TyRefined(u, _, _, _) -> unrefine(u)
    case _ -> t
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
pub func typeEquiv(a: in Type, b: in Type): Bool {
  // Refinements are transparent: a refined type is equivalent to its
  // underlying representation (and vice versa).  Unwrap both sides first
  // so the rest of the comparison never has to know about TyRefined.
  val ua = unrefine(a)
  val ub = unrefine(b)
  match ua {
    case TyError -> true
    case TyVar(_) -> true
    case _ -> match ub { case TyError -> true; case TyVar(_) -> true; case _ -> typeEquivCore(ua, ub) }
  }
}

func typeEquivCore(a: in Type, b: in Type): Bool {
  match a {
    case TyError -> true
    case TyVar(_) -> true
    case TyPrim(pa) -> match b { case TyPrim(pb) -> primEq(pa, pb); case _ -> false }
    case TySelf -> match b { case TySelf -> true; case _ -> false }
    case TyNullable(ia) -> match b { case TyNullable(ib) -> typeEquiv(ia, ib); case _ -> false }
    case TyTuple(xs) -> match b { case TyTuple(ys) -> if xs.count != ys.count { false } else { listTypesEquiv(xs, ys) }; case _ -> false }
    case TyFunction(ps1, r1, asy1) -> match b { case TyFunction(ps2, r2, asy2) -> if asy1 != asy2 { false } else if ps1.count != ps2.count { false } else if not listTypesEquiv(ps1, ps2) { false } else { typeEquiv(r1, r2) }; case _ -> false }
    case TyArray(sz1, e1) -> match b { case TyArray(sz2, e2) -> if not optIntEq(sz1, sz2) { false } else { typeEquiv(e1, e2) }; case _ -> false }
    case TySlice(e1) -> match b { case TySlice(e2) -> typeEquiv(e1, e2); case _ -> false }
    case TyUser(id1, _, args1) -> match b { case TyUser(id2, _, args2) -> if not typeIdEq(id1, id2) { false } else if args1.count != args2.count { false } else { listTypesEquiv(args1, args2) }; case _ -> false }
    case TyException -> match b { case TyException -> true; case _ -> false }
    // `typeEquiv` strips refinements before dispatching here, so this arm
    // is only reached if `typeEquivCore` is called directly; unwrap to be
    // safe and keep the match exhaustive.
    case TyRefined(u, _, _, _) -> typeEquivCore(unrefine(u), unrefine(b))
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
    case TyError -> "<error>"
    case TyException -> "Exception"
    case TySelf -> "Self"
    case TyVar(nm) -> nm
    case TyPrim(pt) -> primName(pt)
    case TyNullable(inner) -> renderType(inner) + "?"
    case TyTuple(elems) -> "(" + joinTypes(elems, ", ") + ")"
    case TySlice(e) -> "slice[" + renderType(e) + "]"
    case TyArray(sz, e) -> match sz { case None -> "array[?, " + renderType(e) + "]"; case Some(n) -> "array[" + toString(n) + ", " + renderType(e) + "]" }
    case TyFunction(ps, r, fAsync) -> {
      val prefix = if fAsync { "async " } else { "" }
      val pstr = "(" + joinTypes(ps, ", ") + ")"
      prefix + pstr + " -> " + renderType(r)
    }
    case TyRefined(u, lo, hi, inc) -> {
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
