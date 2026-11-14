//! ifacebuild_conv.l - checker types to `Lyric.Tir.Ty` for the interface
//! producer (docs/70 §9.2).
//!
//! The checker resolves a declaration's written types to its own `Type`; the
//! interface records `Ty`.  This file converts one into the other.  It imports
//! `Lyric.Tir` and `Lyric.TypeChecker` but not `Lyric.Parser`, whose type
//! expressions share constructor names (`TTuple`, `TArray`, ...) with `Ty`;
//! `Lyric.IfaceBuild` reads the AST and reaches `Ty` only through this file.
package Lyric.IfaceConv

import Std.Core
import Std.Collections
import Std.String as Str
import Lyric.Symbols
import Lyric.Tir
import Lyric.Iface
import Lyric.TypeChecker

/// The generic parameters of one declaration: `owner` is its symbol and `names`
/// its type and value parameters in order, so `TyParam(name, owner)` becomes
/// `TParam(owner, index)`.  Frames nest innermost last.
pub record ConvFrame {
  owner: SymbolId
  names: List[String]
}

/// What a build collects: the problems that make the package unrepresentable,
/// reported by `buildIface` as one error.
pub ref record BuildCtx {
  tbl: SymbolTable
  pkg: String
  errs: List[String]
  /// The number of generic parameters of each type the package declares, by
  /// name, for the `Self` of a `func Type.method` declared outside the type.
  owners: Map[String, Int]
  /// The built default of each parameter that declares one, by the function's DefPath key and then the
  /// parameter's name (`Lyric.Tir.Build.buildPackageDefaults`).
  var defaults: Map[String, Map[String, IfDefault]]
}

pub func newBuildCtx(tbl: in SymbolTable, pkg: in String): BuildCtx {
  BuildCtx(tbl = tbl, pkg = pkg, errs = newList(), owners = newMap(), defaults = newMap())
}

pub func buildFail(bc: in BuildCtx, msg: in String) {
  bc.errs.add(msg)
}

func primTy(pt: in PrimType): Ty {
  match pt {
    case PtBool -> TPrim(kind = TPBool)
    case PtByte -> TPrim(kind = TPByte)
    case PtInt -> TPrim(kind = TPInt)
    case PtLong -> TPrim(kind = TPLong)
    case PtUInt -> TPrim(kind = TPUInt)
    case PtULong -> TPrim(kind = TPULong)
    case PtNat -> TPrim(kind = TPNat)
    case PtFloat -> TPrim(kind = TPFloat)
    case PtDouble -> TPrim(kind = TPDouble)
    case PtChar -> TPrim(kind = TPChar)
    case PtString -> TPrim(kind = TPString)
    case PtUnit -> TPrim(kind = TPUnit)
    case PtNever -> TNever
  }
}

record ParamLoc {
  owner: SymbolId
  index: Int
}

// The innermost frame that declares `name`, with the index inside it.
func findParam(frames: in List[ConvFrame], name: in String): Option[ParamLoc] {
  var f = frames.count - 1
  while f >= 0 {
    val fr = frames[f]
    var i = 0
    while i < fr.names.count {
      if fr.names[i] == name {
        return Some(value = ParamLoc(owner = fr.owner, index = i))
      }
      i = i + 1
    }
    f = f - 1
  }
  None
}

func tysOf(
  bc: in BuildCtx, frames: in List[ConvFrame], selfTy: in Option[Ty], ts: in List[Type], what: in String
): List[Ty] {
  val res: List[Ty] = newList()
  for t in ts {
    res.add(tyOf(bc, frames, selfTy, t, what))
  }
  res
}

/// `t` as a `Ty`.  `selfTy` is the interface whose `Self` is in scope.  A
/// type the interface cannot record (the checker's error type, a `Self` outside
/// an interface, a parameter no frame declares) is a build error naming `what`.
pub func tyOf(bc: in BuildCtx, frames: in List[ConvFrame], selfTy: in Option[Ty], t: in Type, what: in String): Ty {
  match t {
    case TyPrim(pt) -> primTy(pt)
    case TyTuple(elems) -> TTuple(elems = tysOf(bc, frames, selfTy, elems, what))
    case TyNullable(inner) -> TNullable(inner = tyOf(bc, frames, selfTy, inner, what))
    case TyFunction(ps, ret, isAsync) -> {
      val params: List[TParamTy] = newList()
      for p in ps {
        params.add(TParamTy(mode = TMIn, ty = tyOf(bc, frames, selfTy, p, what)))
      }
      TFunc(params = params, ret = tyOf(bc, frames, selfTy, ret, what), isAsync = isAsync)
    }
    case TyArray(size, element, sizeVar) -> {
      val len = match size {
        case Some(n) -> ALKnown(n = n)
        case None -> if hasSizeVar(sizeVar) {
          match findParam(frames, sizeVarName(sizeVar)) {
            case Some(loc) -> ALParam(owner = loc.owner, index = loc.index)
            case None -> {
              buildFail(bc, what + ": array length parameter '" + sizeVarName(sizeVar) + "' is not declared")
              ALUnsized
            }
          }
        } else {
          ALUnsized
        }
      }
      TArray(len = len, element = tyOf(bc, frames, selfTy, element, what))
    }
    case TySlice(element) -> TSlice(element = tyOf(bc, frames, selfTy, element, what))
    case TyUser(id, name, args) -> userTy(bc, frames, selfTy, id, name, args, what)
    case TyRefined(underlying, lo, hi, hiInclusive, _) -> TRefined(
      underlying = tyOf(bc, frames, selfTy, underlying, what),
      lo = lo,
      hi = hi,
      hiInclusive = hiInclusive
    )
    case TySelf -> match selfTy {
      case Some(t) -> t
      case None -> {
        buildFail(bc, what + ": 'Self' where no type or interface is in scope")
        TNever
      }
    }
    case TyLen(n) -> TLen(n = n)
    case TyParam(name, _) -> match findParam(frames, name) {
      case Some(loc) -> TParam(owner = loc.owner, index = loc.index)
      case None -> {
        buildFail(bc, what + ": type parameter '" + name + "' is not declared by the declaration or its owner")
        TNever
      }
    }
    case TyInfer(_) -> {
      buildFail(bc, what + ": an inference variable reached the interface")
      TNever
    }
    case TyError(_) -> {
      buildFail(bc, what + ": the type did not resolve")
      TNever
    }
    case TyException -> TException
  }
}

func userTy(
  bc: in BuildCtx,
  frames: in List[ConvFrame],
  selfTy: in Option[Ty],
  id: in SymbolId,
  name: in String,
  args: in List[Type],
  what: in String,
): Ty {
  val targs = tysOf(bc, frames, selfTy, args, what)
  if isBuiltinSymbol(id) {
    return TNamed(sym = id, args = targs)
  }
  match defPathKeyOf(bc.tbl.interner, id) {
    case None -> {
      buildFail(bc, what + ": type '" + name + "' has no DefPath")
      TNever
    }
    case Some(key) -> if Str.startsWith(key, "extern::") {
      TExtern(host = HostTypeRef(name = Str.substring(key, 8), args = targs))
    } else {
      TNamed(sym = id, args = targs)
    }
  }
}

/// The type a `where` constraint names: the interface declaration it resolves
/// to, or, for a marker with no declaration (a derive marker such as `Equatable`),
/// the path `marker::<name>` interned like any DefPath (D327).
pub func boundTy(bc: in BuildCtx, written: in String, targs: in List[Ty]): Ty {
  match constraintInterfaceSym(bc.tbl, written) {
    case Some(sym) -> match symbolTypeIdOpt(sym) {
      case Some(id) -> TNamed(sym = id, args = targs)
      case None -> markerTy(bc, written, targs)
    }
    case None -> markerTy(bc, written, targs)
  }
}

func markerTy(bc: in BuildCtx, name: in String, targs: in List[Ty]): Ty {
  TNamed(sym = internDefPath(bc.tbl.interner, topDefPath("marker", name)), args = targs)
}

/// A generic parameter record.
pub func mkTypeParam(name: in String, bounds: in List[Ty], valueTy: in Option[Ty]): TTypeParam {
  TTypeParam(name = name, bounds = bounds, valueTy = valueTy)
}

/// A parameter of a function; `modeCode` is 0 for `in`, 1 for `out`, 2 for `inout`.
pub func mkParam(name: in String, modeCode: in Int, ty: in Ty, hasDefault: in Bool): IfParam {
  val mode = if modeCode == 1 { TMOut } else if modeCode == 2 { TMInout } else { TMIn }
  IfParam(name = name, mode = mode, ty = ty, hasDefault = hasDefault)
}

pub func mkField(name: in String, ty: in Ty, mutable: in Bool, hasDefault: in Bool): IfField {
  IfField(name = name, ty = ty, mutable = mutable, hasDefault = hasDefault)
}

pub func mkTypeParams(): List[TTypeParam] {
  newList()
}

pub func tyUnitValue(): Ty {
  tyUnit()
}

pub func tyIntValue(): Ty {
  tyInt()
}

/// A range subtype's underlying type with its bounds: `TRefined` over `base`.
pub func mkRefined(base: in Ty, lo: in Option[Long], hi: in Option[Long], hiInclusive: in Bool): Ty {
  TRefined(underlying = base, lo = lo, hi = hi, hiInclusive = hiInclusive)
}

pub func mkLitInt(v: in Long): TLit {
  TLInt(value = v)
}

pub func mkLitString(s: in String): TLit {
  TLString(text = s)
}

pub func mkLitBool(b: in Bool): TLit {
  TLBool(value = b)
}

pub func mkLitFloat(v: in Double): TLit {
  TLFloat(value = v)
}

pub func mkLitChar(cp: in Int): TLit {
  TLChar(codepoint = cp)
}

/// `Self` inside the interface `iface`: its own `Self` parameter.
pub func selfOfInterface(iface: in SymbolId): Ty {
  tySelfOf(iface)
}

/// `Self` inside the type `owner`'s methods: the type applied to its own
/// generic parameters, in declaration order.
pub func selfOfType(owner: in SymbolId, paramCount: in Int): Ty {
  val args: List[Ty] = newList()
  var i = 0
  while i < paramCount {
    args.add(TParam(owner = owner, index = i))
    i = i + 1
  }
  TNamed(sym = owner, args = args)
}
