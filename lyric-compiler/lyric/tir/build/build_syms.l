//! build_syms.l - the `TSymEntry` of every declaration the builder uses
//! (docs/70 §6.2, §6.4): the oracle `Lyric.Tir.Verify` checks calls and
//! constructions against.  Entries come from the signatures the checker
//! recorded per call, so a package's table holds exactly the declarations its
//! bodies reach.
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
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

/// Fill `ctx.cases` once: every union and enum case symbol of the table by the
/// `SymbolId` the checker gives it.
func loadCases(ctx: in TyConvCtx): Unit {
  if ctx.casesLoaded.count > 0 {
    return
  }
  ctx.casesLoaded.add(true)
  for s in ctx.tbl.symbols {
    match s.kind {
      case DKUnionCase(pid, uc) -> match caseSymbolId(ctx.tbl, s, pid, uc.name) {
        case Some(id) -> if not ctx.cases.containsKey(id.id) { ctx.cases.add(id.id, s) }
        case None -> ()
      }
      case DKEnumCase(pid, ec) -> match caseSymbolId(ctx.tbl, s, pid, ec.name) {
        case Some(id) -> if not ctx.cases.containsKey(id.id) { ctx.cases.add(id.id, s) }
        case None -> ()
      }
      case _ -> ()
    }
  }
}

/// The result type of a case of the union or enum `parent` with `n` type parameters.
func caseResultTy(parent: in SymbolId, n: in Int): Ty {
  val args: List[Ty] = newList()
  var i = 0
  while i < n {
    args.add(TParam(owner = parent, index = i))
    i = i + 1
  }
  TNamed(sym = parent, args = args)
}

/// Record the union or enum case `sym`, when it is one: a payload as parameters and
/// fields, the union (under its own parameters) as the result.  The payload types are
/// converted in a context where the union's parameters belong to the union.  A case
/// whose payload cannot be converted leaves no entry.
func noteCaseSym(env: in BuildEnv, sym: in SymbolId): Unit {
  if env.syms.containsKey(sym.id) {
    return
  }
  loadCases(env.ctx)
  val s = match mapGet(env.ctx.cases, sym.id) { case Some(x) -> x; case None -> return }
  val tbl = env.ctx.tbl
  match s.kind {
    case DKEnumCase(pid, _) -> env.syms.add(
      sym.id,
      TSymEntry(
        sym = sym,
        kind = TSkCase,
        typeParamCount = 0,
        sig = Some(
          value = TSig(
            typeParamCount = 0,
            params = newList(),
            ret = caseResultTy(pid, 0),
            isAsync = false
          )
        ),
        fields = newList(),
        ty = None,
        mutable = false
      )
    )
    case DKUnionCase(pid, uc) -> {
      val decl = match parentUnionDeclOf(tbl, pid) { case Some(d) -> d; case None -> return }
      val names = unionDeclGenericNames(decl)
      val ctx = newTyConvCtx(tbl)
      val gc = GenericContext(params = newList(), owners = newList(), stackDepths = newList())
      if names.count > 0 {
        tyConvBind(ctx, decl.name, pid, names)
        gctxPushOwned(gc, names, decl.name)
      }
      val diag: List[Diagnostic] = newList()
      val ps: List[TParamTy] = newList()
      val fs: List[TFieldSig] = newList()
      var i = 0
      for f in uc.fields {
        val fname = match f { case UFNamed(n, _, _) -> n; case UFPos(_, _) -> "_" + toString(i) }
        val te = match f { case UFNamed(_, t, _) -> t; case UFPos(t, _) -> t }
        match tyOfType(ctx, resolveType(tbl, gc, diag, te)) {
          case Ok(t) -> {
            ps.add(TParamTy(mode = TMIn, ty = t))
            fs.add(TFieldSig(name = fname, ty = t, mutable = false))
          }
          case Err(_) -> return
        }
        i = i + 1
      }
      env.syms.add(
        sym.id,
        TSymEntry(
          sym = sym,
          kind = TSkCase,
          typeParamCount = names.count,
          sig = Some(
            value = TSig(
              typeParamCount = names.count,
              params = ps,
              ret = caseResultTy(pid, names.count),
              isAsync = false
            )
          ),
          fields = fs,
          ty = None,
          mutable = false
        )
      )
    }
    case _ -> ()
  }
}

/// `p` after recording the case `sym` it matches.
func withCaseSym(env: in BuildEnv, sym: in SymbolId, p: in TPat): TPat {
  noteCaseSym(env, sym)
  p
}

func typeEntry(sym: in SymbolId, n: in Int, fields: in List[TFieldSig]): TSymEntry {
  TSymEntry(sym = sym, kind = TSkType, typeParamCount = n, sig = None, fields = fields, ty = None, mutable = false)
}

/// The entry of every type the table declares, records with their fields: the
/// oracle for a `TNamed` in any type and for a field read.  A record whose field
/// types cannot be converted gets no entry, so a use of it is reported rather than
/// checked against a partial field list.
pub func typeEntries(tbl: in SymbolTable): List[TSymEntry] {
  val res: List[TSymEntry] = newList()
  val seen: Map[Int, Bool] = newMap()
  for s in tbl.symbols {
    var id: Option[SymbolId] = None
    var isRecord = false
    match s.kind {
      case DKRecord(i, _) -> {
        id = Some(value = i)
        isRecord = true
      }
      case DKExposedRec(i, _) -> {
        id = Some(value = i)
        isRecord = true
      }
      case DKUnion(i, _) -> {
        id = Some(value = i)
      }
      case DKEnum(i, _) -> {
        id = Some(value = i)
      }
      case DKOpaque(i, _) -> {
        id = Some(value = i)
      }
      case DKProtected(i, _) -> {
        id = Some(value = i)
      }
      case DKDistinctType(i, _) -> {
        id = Some(value = i)
      }
      case DKInterface(i, _) -> {
        id = Some(value = i)
      }
      case DKExternType(i, _) -> {
        id = Some(value = i)
      }
      case _ -> ()
    }
    match id {
      case Some(sid) -> if not seen.containsKey(sid.id) {
        seen.add(sid.id, true)
        if isRecord {
          val names = recordGenericNamesOf(tbl, sid)
          val ctx = newTyConvCtx(tbl)
          if names.count > 0 {
            tyConvBind(ctx, s.name, sid, names)
          }
          val fs: List[TFieldSig] = newList()
          var ok = true
          for f in fieldsOfRecord(tbl, sid) {
            match tyOfType(ctx, f.ty) {
              case Ok(t) -> fs.add(TFieldSig(name = f.name, ty = t, mutable = false))
              case Err(_) -> {
                ok = false
              }
            }
          }
          if ok {
            res.add(typeEntry(sid, names.count, fs))
          }
        } else {
          res.add(typeEntry(sid, 0, newList()))
        }
      }
      case None -> ()
    }
  }
  res
}

/// Record the module value or function value `sym` a body reads, with the type the checker
/// gave the reading.  A `val` and a `const` are not assignable.
func noteGlobalSym(env: in BuildEnv, sym: in SymbolId, ty: in Ty): Unit {
  if env.syms.containsKey(sym.id) {
    return
  }
  env.syms.add(
    sym.id,
    TSymEntry(
      sym = sym,
      kind = TSkVal,
      typeParamCount = 0,
      sig = None,
      fields = newList(),
      ty = Some(value = ty),
      mutable = false
    )
  )
}
