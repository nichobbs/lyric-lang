//! iface_ty.l - the codec of `Lyric.Tir.Ty` and the pieces of a declaration
//! built from it (docs/70 §9.2).
//!
//! A `Ty` names declarations by `SymbolId`, an id that exists only within one
//! compilation.  An interface records the declaration's DefPath key instead
//! (`defPathKey`), and a reader interns the key into its own
//! `DefPathInterner`, so one declaration is one id wherever it is met.  A
//! built-in type with no declaration (`Task[T]`, `buffer[T]`) has a negative id
//! and is written as that number.
package Lyric.Iface

import Std.Core
import Std.Collections
import Std.Math as Math
import Lyric.Symbols
import Lyric.Tir

func primCode(k: in TPrimKind): Int {
  match k {
    case TPBool -> 0
    case TPByte -> 1
    case TPInt -> 2
    case TPLong -> 3
    case TPUInt -> 4
    case TPULong -> 5
    case TPNat -> 6
    case TPFloat -> 7
    case TPDouble -> 8
    case TPChar -> 9
    case TPString -> 10
    case TPUnit -> 11
  }
}

func primOfCode(c: in Int): Option[TPrimKind] {
  match c {
    case 0 -> Some(value = TPBool)
    case 1 -> Some(value = TPByte)
    case 2 -> Some(value = TPInt)
    case 3 -> Some(value = TPLong)
    case 4 -> Some(value = TPUInt)
    case 5 -> Some(value = TPULong)
    case 6 -> Some(value = TPNat)
    case 7 -> Some(value = TPFloat)
    case 8 -> Some(value = TPDouble)
    case 9 -> Some(value = TPChar)
    case 10 -> Some(value = TPString)
    case 11 -> Some(value = TPUnit)
    case _ -> None
  }
}

func modeCode(m: in TMode): Int {
  match m {
    case TMIn -> 0
    case TMOut -> 1
    case TMInout -> 2
  }
}

func modeOfCode(c: in Int): Option[TMode] {
  match c {
    case 0 -> Some(value = TMIn)
    case 1 -> Some(value = TMOut)
    case 2 -> Some(value = TMInout)
    case _ -> None
  }
}

// ── Declaration references ───────────────────────────────────────────────────
pub func putSym(w: in IfaceWriter, it: in DefPathInterner, s: in SymbolId) {
  if isBuiltinSymbol(s) {
    putU(w, 0)
    putU(w, 0 - s.id)
  } else {
    match defPathKeyOf(it, s) {
      case Some(key) -> {
        putU(w, 1)
        putStr(w, key)
      }
      case None -> {
        writeFail(w, "a type names a declaration that has no DefPath (symbol " + toString(s.id) + ")")
        putU(w, 0)
        putU(w, 0)
      }
    }
  }
}

pub func readSym(r: in IfaceReader, it: in DefPathInterner): SymbolId {
  val tag = readU(r)
  if tag == 0 {
    val n = readU(r)
    SymbolId(id = 0 - n)
  } else if tag == 1 {
    internDefPathKey(it, readStr(r))
  } else {
    readFail(r, "unknown declaration reference tag " + toString(tag))
    SymbolId(id = 0)
  }
}

// ── Ty ───────────────────────────────────────────────────────────────────────
func putTys(w: in IfaceWriter, it: in DefPathInterner, xs: in List[Ty]) {
  putU(w, xs.count)
  for x in xs {
    putTy(w, it, x)
  }
}

func putOptLong(w: in IfaceWriter, v: in Option[Long]) {
  match v {
    case None -> putBool(w, false)
    case Some(n) -> {
      putBool(w, true)
      putLong(w, n)
    }
  }
}

pub func putTy(w: in IfaceWriter, it: in DefPathInterner, t: in Ty) {
  match t {
    case TPrim(k) -> {
      putU(w, 0)
      putU(w, primCode(k))
    }
    case TTuple(xs) -> {
      putU(w, 1)
      putTys(w, it, xs)
    }
    case TNullable(inner) -> {
      putU(w, 2)
      putTy(w, it, inner)
    }
    case TFunc(ps, ret, isAsync) -> {
      putU(w, 3)
      putU(w, ps.count)
      for p in ps {
        putU(w, modeCode(p.mode))
        putTy(w, it, p.ty)
      }
      putTy(w, it, ret)
      putBool(w, isAsync)
    }
    case TArray(len, elem) -> {
      putU(w, 4)
      match len {
        case ALKnown(n) -> {
          putU(w, 0)
          putU(w, n)
        }
        case ALParam(owner, index) -> {
          putU(w, 1)
          putSym(w, it, owner)
          putU(w, index)
        }
        case ALUnsized -> putU(w, 2)
      }
      putTy(w, it, elem)
    }
    case TSlice(elem) -> {
      putU(w, 5)
      putTy(w, it, elem)
    }
    case TNamed(sym, args) -> {
      putU(w, 6)
      putSym(w, it, sym)
      putTys(w, it, args)
    }
    case TParam(owner, index) -> {
      putU(w, 7)
      putSym(w, it, owner)
      putU(w, index + 1)
    }
    case TRefined(underlying, lo, hi, hiInclusive) -> {
      putU(w, 8)
      putTy(w, it, underlying)
      putOptLong(w, lo)
      putOptLong(w, hi)
      putBool(w, hiInclusive)
    }
    case TLen(n) -> {
      putU(w, 9)
      putU(w, n)
    }
    case TNever -> putU(w, 10)
    case TException -> putU(w, 11)
    case TExtern(host) -> {
      putU(w, 12)
      putStr(w, host.name)
      putTys(w, it, host.args)
    }
  }
}

func readTys(r: in IfaceReader, it: in DefPathInterner): List[Ty] {
  val n = readCount(r)
  val res: List[Ty] = newList()
  var k = 0
  while k < n and not r.failed {
    res.add(readTy(r, it))
    k = k + 1
  }
  res
}

func readOptLong(r: in IfaceReader): Option[Long] {
  if readBool(r) {
    Some(value = readLong(r))
  } else {
    None
  }
}

/// Reads a type.  A malformed file yields `TNever` and sets the reader's
/// failure, so the caller never uses the value.
pub func readTy(r: in IfaceReader, it: in DefPathInterner): Ty {
  if not readEnter(r) {
    return TNever
  }
  val t = readTyBody(r, it)
  readLeave(r)
  t
}

func readTyBody(r: in IfaceReader, it: in DefPathInterner): Ty {
  val tag = readU(r)
  if r.failed {
    return TNever
  }
  match tag {
    case 0 -> {
      val c = readU(r)
      match primOfCode(c) {
        case Some(k) -> TPrim(kind = k)
        case None -> {
          readFail(r, "unknown primitive type " + toString(c))
          TNever
        }
      }
    }
    case 1 -> TTuple(elems = readTys(r, it))
    case 2 -> TNullable(inner = readTy(r, it))
    case 3 -> {
      val n = readCount(r)
      val ps: List[TParamTy] = newList()
      var k = 0
      while k < n and not r.failed {
        val mc = readU(r)
        val ty = readTy(r, it)
        match modeOfCode(mc) {
          case Some(m) -> ps.add(TParamTy(mode = m, ty = ty))
          case None -> readFail(r, "unknown parameter mode " + toString(mc))
        }
        k = k + 1
      }
      val ret = readTy(r, it)
      TFunc(params = ps, ret = ret, isAsync = readBool(r))
    }
    case 4 -> {
      val lt = readU(r)
      val len = if lt == 0 {
        ALKnown(n = readU(r))
      } else if lt == 1 {
        val owner = readSym(r, it)
        ALParam(owner = owner, index = readU(r))
      } else {
        if lt != 2 {
          readFail(r, "unknown array length tag " + toString(lt))
        }
        ALUnsized
      }
      TArray(len = len, element = readTy(r, it))
    }
    case 5 -> TSlice(element = readTy(r, it))
    case 6 -> {
      val sym = readSym(r, it)
      TNamed(sym = sym, args = readTys(r, it))
    }
    case 7 -> {
      val owner = readSym(r, it)
      TParam(owner = owner, index = readU(r) - 1)
    }
    case 8 -> {
      val u = readTy(r, it)
      val lo = readOptLong(r)
      val hi = readOptLong(r)
      TRefined(underlying = u, lo = lo, hi = hi, hiInclusive = readBool(r))
    }
    case 9 -> TLen(n = readU(r))
    case 10 -> TNever
    case 11 -> TException
    case 12 -> {
      val name = readStr(r)
      TExtern(host = HostTypeRef(name = name, args = readTys(r, it)))
    }
    case _ -> {
      readFail(r, "unknown type tag " + toString(tag))
      TNever
    }
  }
}

// ── Generic parameters, literals ────────────────────────────────────────────
pub func putTypeParams(w: in IfaceWriter, it: in DefPathInterner, ps: in List[TTypeParam]) {
  putU(w, ps.count)
  for p in ps {
    putStr(w, p.name)
    putTys(w, it, p.bounds)
    match p.valueTy {
      case None -> putBool(w, false)
      case Some(t) -> {
        putBool(w, true)
        putTy(w, it, t)
      }
    }
  }
}

pub func readTypeParams(r: in IfaceReader, it: in DefPathInterner): List[TTypeParam] {
  val n = readCount(r)
  val res: List[TTypeParam] = newList()
  var k = 0
  while k < n and not r.failed {
    val name = readStr(r)
    val bounds = readTys(r, it)
    val valueTy = if readBool(r) then Some(value = readTy(r, it)) else None
    res.add(TTypeParam(name = name, bounds = bounds, valueTy = valueTy))
    k = k + 1
  }
  res
}

pub func putLit(w: in IfaceWriter, l: in TLit) {
  match l {
    case TLInt(v) -> {
      putU(w, 0)
      putLong(w, v)
    }
    case TLFloat(v) -> {
      putU(w, 1)
      putLong(w, Math.doubleToBits(v))
    }
    case TLChar(cp) -> {
      putU(w, 2)
      putU(w, cp)
    }
    case TLString(s) -> {
      putU(w, 3)
      putStr(w, s)
    }
    case TLBool(b) -> {
      putU(w, 4)
      putBool(w, b)
    }
    case TLUnit -> putU(w, 5)
  }
}

pub func readLit(r: in IfaceReader): TLit {
  val tag = readU(r)
  match tag {
    case 0 -> TLInt(value = readLong(r))
    case 1 -> TLFloat(value = Math.doubleFromBits(readLong(r)))
    case 2 -> TLChar(codepoint = readU(r))
    case 3 -> TLString(text = readStr(r))
    case 4 -> TLBool(value = readBool(r))
    case 5 -> TLUnit
    case _ -> {
      readFail(r, "unknown literal tag " + toString(tag))
      TLUnit
    }
  }
}
