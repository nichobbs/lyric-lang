//! tir_ty.l - Lyric.Tir: identities and the type language (docs/70 §6.2, D319).
//!
//! `Ty` is the type of every TIR node.  It has no error case and no inference
//! case: TIR is built only from a package that type-checked without errors, so
//! a value of this type is always a real type.  It also holds nothing the
//! checker owns (no scope, no environment, no `TypeExpr`): a declaration is
//! named by the `SymbolId` of `Lyric.Symbols`, so package interfaces (docs/70
//! §9) use the same type for the signatures they record.
//!
//! `Self` inside an interface declaration is the parameter
//! `TParam(owner = <interface>, index = selfParamIndex())`; everywhere else it
//! has already been replaced by the type it stands for.
package Lyric.Tir

import Std.Core
import Std.Collections
import Lyric.Symbols

/// A node of a TIR package, unique within the package (docs/70 §6.1).
pub record NodeId {
  id: Int
}

/// A local variable, parameter or pattern binding, unique within the package.
pub record LocalId {
  id: Int
}

pub func nodeIdEq(a: in NodeId, b: in NodeId): Bool {
  a.id == b.id
}

pub func localIdEq(a: in LocalId, b: in LocalId): Bool {
  a.id == b.id
}

/// The scalar types.  `Never` is `Ty.TNever`, not a member of this union.
pub union TPrimKind {
  case TPBool
  case TPByte
  case TPInt
  case TPLong
  case TPUInt
  case TPULong
  case TPNat
  case TPFloat
  case TPDouble
  case TPChar
  case TPString
  case TPUnit
}

/// How a parameter or argument passes its value.
pub union TMode {
  case TMIn
  case TMOut
  case TMInout
}

/// A parameter of a function type: its mode and its type.
pub record TParamTy {
  mode: TMode
  ty: Ty
}

/// The length of an array type.
pub union ArrayLen {
  /// `array[3, T]`.
  case ALKnown(n: Int)
  /// `array[N, T]` in a value-generic declaration: the value parameter
  /// `index` of `owner`.
  case ALParam(owner: SymbolId, index: Int)
  /// `array[_, T]`: the length is not part of the type.
  case ALUnsized
}

/// A host (extern) type: the CLR or JVM type an `extern type` names, with its
/// type arguments.  `name` is the host's own spelling (`System.Math`,
/// `java.util.ArrayList`); two extern declarations naming one host type are one
/// `HostTypeRef` (docs/70 §4.2).
pub record HostTypeRef {
  name: String
  args: List[Ty]
}

pub union Ty {
  case TPrim(kind: TPrimKind)
  case TTuple(elems: List[Ty])
  case TNullable(inner: Ty)
  case TFunc(params: List[TParamTy], ret: Ty, isAsync: Bool)
  case TArray(len: ArrayLen, element: Ty)
  case TSlice(element: Ty)
  /// A declared or built-in type applied to its arguments.  Value generic
  /// arguments are `TLen`.
  case TNamed(sym: SymbolId, args: List[Ty])
  /// A rigid generic parameter: equal only to itself.  `index` counts the
  /// declaration's own parameters, value parameters included.
  case TParam(owner: SymbolId, index: Int)
  /// A refinement of a numeric type; `lo`/`hi` are absent for an open end.
  case TRefined(underlying: Ty, lo: Option[Long], hi: Option[Long], hiInclusive: Bool)
  /// A known length used as a value generic argument.
  case TLen(n: Int)
  case TNever
  /// The type a `catch` clause binds.
  case TException
  case TExtern(host: HostTypeRef)
}

/// The index of the `Self` parameter of an interface: `TParam(iface, -1)`.
pub func selfParamIndex(): Int {
  -1
}

pub func tyUnit(): Ty {
  TPrim(TPUnit)
}

pub func tyBool(): Ty {
  TPrim(TPBool)
}

pub func tyInt(): Ty {
  TPrim(TPInt)
}

pub func tyString(): Ty {
  TPrim(TPString)
}

pub func tySelfOf(iface: in SymbolId): Ty {
  TParam(owner = iface, index = selfParamIndex())
}

/// The ids the checker gives its built-in types (`Task[T]`, `buffer[T]`) are
/// negative: no declaration names them.
pub func isBuiltinSymbol(s: in SymbolId): Bool {
  s.id < 0
}

pub func primKindEq(a: in TPrimKind, b: in TPrimKind): Bool {
  primKindName(a) == primKindName(b)
}

pub func primKindName(k: in TPrimKind): String {
  match k {
    case TPBool -> "Bool"
    case TPByte -> "Byte"
    case TPInt -> "Int"
    case TPLong -> "Long"
    case TPUInt -> "UInt"
    case TPULong -> "ULong"
    case TPNat -> "Nat"
    case TPFloat -> "Float"
    case TPDouble -> "Double"
    case TPChar -> "Char"
    case TPString -> "String"
    case TPUnit -> "Unit"
  }
}

pub func modeEq(a: in TMode, b: in TMode): Bool {
  match a {
    case TMIn -> match b { case TMIn -> true; case _ -> false }
    case TMOut -> match b { case TMOut -> true; case _ -> false }
    case TMInout -> match b { case TMInout -> true; case _ -> false }
  }
}

pub func modeName(m: in TMode): String {
  match m {
    case TMIn -> "in"
    case TMOut -> "out"
    case TMInout -> "inout"
  }
}

func optLongEq(a: in Option[Long], b: in Option[Long]): Bool {
  match a {
    case None -> match b { case None -> true; case Some(_) -> false }
    case Some(x) -> match b { case None -> false; case Some(y) -> x == y }
  }
}

pub func arrayLenEq(a: in ArrayLen, b: in ArrayLen): Bool {
  match a {
    case ALKnown(n) -> match b { case ALKnown(m) -> n == m; case _ -> false }
    case ALParam(o1, i1) -> match b { case ALParam(o2, i2) -> symbolIdEq(o1, o2) and i1 == i2; case _ -> false }
    case ALUnsized -> match b { case ALUnsized -> true; case _ -> false }
  }
}

pub func tyListEq(xs: in List[Ty], ys: in List[Ty]): Bool {
  if xs.count != ys.count {
    return false
  }
  var i = 0
  var ok = true
  while ok and i < xs.count {
    if not tyEq(xs[i], ys[i]) {
      ok = false
    }
    i = i + 1
  }
  ok
}

func paramTysEq(xs: in List[TParamTy], ys: in List[TParamTy]): Bool {
  if xs.count != ys.count {
    return false
  }
  var i = 0
  var ok = true
  while ok and i < xs.count {
    if not modeEq(xs[i].mode, ys[i].mode) or not tyEq(xs[i].ty, ys[i].ty) {
      ok = false
    }
    i = i + 1
  }
  ok
}

/// Structural equality.  Nothing is a wildcard: a parameter equals only the
/// same parameter, and a refinement equals only a refinement with the same
/// bounds (a conversion between a refined type and its underlying type is an
/// explicit node, so TIR never relies on refinement being transparent).
pub func tyEq(a: in Ty, b: in Ty): Bool {
  match a {
    case TPrim(ka) -> match b { case TPrim(kb) -> primKindEq(ka, kb); case _ -> false }
    case TTuple(xs) -> match b { case TTuple(ys) -> tyListEq(xs, ys); case _ -> false }
    case TNullable(ia) -> match b { case TNullable(ib) -> tyEq(ia, ib); case _ -> false }
    case TFunc(p1, r1, a1) -> match b {
      case TFunc(p2, r2, a2) -> a1 == a2 and paramTysEq(p1, p2) and tyEq(r1, r2)
      case _ -> false
    }
    case TArray(l1, e1) -> match b { case TArray(l2, e2) -> arrayLenEq(l1, l2) and tyEq(e1, e2); case _ -> false }
    case TSlice(e1) -> match b { case TSlice(e2) -> tyEq(e1, e2); case _ -> false }
    case TNamed(s1, a1) -> match b { case TNamed(s2, a2) -> symbolIdEq(s1, s2) and tyListEq(a1, a2); case _ -> false }
    case TParam(o1, i1) -> match b { case TParam(o2, i2) -> symbolIdEq(o1, o2) and i1 == i2; case _ -> false }
    case TRefined(u1, lo1, hi1, inc1) -> match b {
      case TRefined(u2, lo2, hi2, inc2) -> tyEq(u1, u2) and optLongEq(lo1, lo2) and
        optLongEq(hi1, hi2) and
        inc1 == inc2
      case _ -> false
    }
    case TLen(n) -> match b { case TLen(m) -> n == m; case _ -> false }
    case TNever -> match b { case TNever -> true; case _ -> false }
    case TException -> match b { case TException -> true; case _ -> false }
    case TExtern(h1) -> match b {
      case TExtern(h2) -> h1.name == h2.name and tyListEq(h1.args, h2.args)
      case _ -> false
    }
  }
}

func renderTyList(xs: in List[Ty]): String {
  var s = ""
  var i = 0
  while i < xs.count {
    if i > 0 {
      s = s + ", "
    }
    s = s + renderTy(xs[i])
    i = i + 1
  }
  s
}

func renderOptLong(o: in Option[Long], dflt: in String): String {
  match o {
    case None -> dflt
    case Some(v) -> toString(v)
  }
}

/// A stable, human-readable spelling for diagnostics.  A declaration shows as
/// `#<id>`: this package does not know names, only identities.
pub func renderTy(t: in Ty): String {
  match t {
    case TPrim(k) -> primKindName(k)
    case TTuple(xs) -> "(" + renderTyList(xs) + ")"
    case TNullable(i) -> renderTy(i) + "?"
    case TFunc(ps, r, asy) -> {
      var s = if asy { "async func(" } else { "func(" }
      var i = 0
      while i < ps.count {
        if i > 0 {
          s = s + ", "
        }
        s = s + modeName(ps[i].mode) + " " + renderTy(ps[i].ty)
        i = i + 1
      }
      s + "): " + renderTy(r)
    }
    case TArray(len, e) -> match len {
      case ALKnown(n) -> "array[" + toString(n) + ", " + renderTy(e) + "]"
      case ALParam(o, i) -> "array[#" + toString(o.id) + "." + toString(i) + ", " + renderTy(e) +
        "]"
      case ALUnsized -> "array[_, " + renderTy(e) + "]"
    }
    case TSlice(e) -> "slice[" + renderTy(e) + "]"
    case TNamed(s, args) -> if args.count == 0 {
      "#" + toString(s.id)
    } else {
      "#" + toString(s.id) + "[" + renderTyList(args) + "]"
    }
    case TParam(o, i) -> "param(#" + toString(o.id) + ", " + toString(i) + ")"
    case TRefined(u, lo, hi, inc) -> renderTy(u) + " range " + renderOptLong(lo, "MIN") +
      (if inc { " ..= " } else { " .. " }) +
      renderOptLong(hi, "MAX")
    case TLen(n) -> toString(n)
    case TNever -> "Never"
    case TException -> "Exception"
    case TExtern(h) -> if h.args.count == 0 {
      "extern " + h.name
    } else {
      "extern " + h.name + "[" + renderTyList(h.args) + "]"
    }
  }
}

/// `t` with the type parameters of `owner` replaced by `args` (by index): a case's field types
/// read at the arguments of the union a construction is converted to.
pub func substOwnerArgs(t: in Ty, owner: in SymbolId, args: in List[Ty]): Ty {
  match t {
    case TPrim(_) -> t
    case TTuple(xs) -> TTuple(elems = substOwnerArgsList(xs, owner, args))
    case TNullable(i) -> TNullable(inner = substOwnerArgs(i, owner, args))
    case TFunc(ps, r, asy) -> {
      val res: List[TParamTy] = newList()
      for p in ps {
        res.add(TParamTy(mode = p.mode, ty = substOwnerArgs(p.ty, owner, args)))
      }
      TFunc(params = res, ret = substOwnerArgs(r, owner, args), isAsync = asy)
    }
    case TArray(len, e) -> TArray(len = len, element = substOwnerArgs(e, owner, args))
    case TSlice(e) -> TSlice(element = substOwnerArgs(e, owner, args))
    case TNamed(s, xs) -> TNamed(sym = s, args = substOwnerArgsList(xs, owner, args))
    case TParam(o, i) -> if symbolIdEq(o, owner) and i >= 0 and i < args.count { args[i] } else { t }
    case TRefined(u, lo, hi, inc) -> TRefined(
      underlying = substOwnerArgs(u, owner, args),
      lo = lo,
      hi = hi,
      hiInclusive = inc
    )
    case TLen(_) -> t
    case TNever -> t
    case TException -> t
    case TExtern(h) -> TExtern(host = HostTypeRef(name = h.name, args = substOwnerArgsList(h.args, owner, args)))
  }
}

pub func substOwnerArgsList(xs: in List[Ty], owner: in SymbolId, args: in List[Ty]): List[Ty] {
  val res: List[Ty] = newList()
  for x in xs {
    res.add(substOwnerArgs(x, owner, args))
  }
  res
}
