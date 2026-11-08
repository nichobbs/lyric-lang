//! build_syms.l - the `TSymEntry` of every declaration the builder uses
//! (docs/70 §6.2, §6.4): the oracle `Lyric.Tir.Verify` checks calls and
//! constructions against.  Entries come from the signatures the checker
//! recorded per call, so a package's table holds exactly the declarations its
//! bodies reach.
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Symbols
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Tir

func modeOfParam(m: in ParamMode): TMode {
  match m {
    case PMIn -> TMIn
    case PMOut -> TMOut
    case PMInout -> TMInout
  }
}

/// The signature `sig` as a `TSig` declared by `sym`, its generic parameters
/// owned by `sym`.  The conversion uses its own context: the binder keys the
/// checker gives (`fn.name`) are not unique across packages, so they must not
/// replace the ones the body being built has registered.  `recv` is a method's
/// receiver, a leading parameter the checker keeps apart.
func tsigOf(
  tbl: in SymbolTable,
  sym: in SymbolId,
  sig: in ResolvedSignature,
  recv: in Option[Type],
  recvMode: in Option[ParamMode],
): Result[TSig, String] {
  val ctx = newTyConvCtx(tbl)
  if sig.genericOwners.count > 0 {
    for o in sig.genericOwners {
      tyConvBind(ctx, o, sym, sig.generics)
    }
  }
  val ps: List[TParamTy] = newList()
  match recv {
    case Some(rt) -> match tyOfType(ctx, rt) {
      case Ok(t) -> {
        val m = match recvMode { case Some(x) -> modeOfParam(x); case None -> TMIn }
        ps.add(TParamTy(mode = m, ty = t))
      }
      case Err(msg) -> return Err(error = msg)
    }
    case None -> ()
  }
  for p in sig.params {
    match tyOfType(ctx, p.ty) {
      case Ok(t) -> ps.add(TParamTy(mode = modeOfParam(p.mode), ty = t))
      case Err(msg) -> return Err(error = msg)
    }
  }
  match tyOfType(ctx, sig.returnTy) {
    case Ok(r) -> Ok(value = TSig(typeParamCount = sig.generics.count, params = ps, ret = r, isAsync = sig.isAsync))
    case Err(msg) -> Err(error = msg)
  }
}

/// Record the function `sym` the body being built calls.  A signature that
/// cannot be converted leaves no entry, so the verifier reports the callee
/// undefined rather than the builder failing the body.
func noteFuncSym(
  env: in BuildEnv,
  sym: in SymbolId,
  sig: in ResolvedSignature,
  recv: in Option[Type],
  recvMode: in Option[ParamMode],
  kind: in TSymKind,
): Unit {
  if env.syms.containsKey(sym.id) {
    return
  }
  match tsigOf(env.ctx.tbl, sym, sig, recv, recvMode) {
    case Ok(ts) -> env.syms.add(
      sym.id,
      TSymEntry(
        sym = sym,
        kind = kind,
        typeParamCount = sig.generics.count,
        sig = Some(value = ts),
        fields = newList(),
        ty = None,
        mutable = false
      )
    )
    case Err(_) -> ()
  }
}

/// Record the record or case `sym` a non-generic construction builds: its
/// fields are the constructor signature's parameters.
func noteCtorSym(env: in BuildEnv, sym: in SymbolId, sig: in ResolvedSignature): Unit {
  if env.syms.containsKey(sym.id) {
    return
  }
  val ctx = newTyConvCtx(env.ctx.tbl)
  val fs: List[TFieldSig] = newList()
  for p in sig.params {
    match tyOfType(ctx, p.ty) {
      case Ok(t) -> fs.add(TFieldSig(name = p.name, ty = t, mutable = false))
      case Err(_) -> return
    }
  }
  env.syms.add(
    sym.id,
    TSymEntry(sym = sym, kind = TSkType, typeParamCount = 0, sig = None, fields = fs, ty = None, mutable = false)
  )
}

/// The entry of a function the package declares, from its built declaration.
func ownFnEntry(f: in TFnDecl): TSymEntry {
  val ps: List[TParamTy] = newList()
  for p in f.params {
    ps.add(TParamTy(mode = p.mode, ty = p.local.ty))
  }
  TSymEntry(
    sym = f.sym,
    kind = TSkFunc,
    typeParamCount = f.typeParams.count,
    sig = Some(value = TSig(typeParamCount = f.typeParams.count, params = ps, ret = f.ret, isAsync = f.isAsync)),
    fields = newList(),
    ty = None,
    mutable = false
  )
}
