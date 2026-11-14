//! build.l - Lyric.Tir.Build: the TIR builder (docs/70 §6.3, D360).
//!
//! The builder turns a type-checked package into `Lyric.Tir`, reading what the
//! checker recorded per `NodeId` (`SymbolTable.exprTypes`) and failing with
//! I0002 on any node with no entry.  This file holds the type conversion every
//! node needs: the checker's `Type` to `Lyric.Tir.Ty`, which has no error and
//! no inference case, so a type the checker could not give is an I0002 here
//! and never a wildcard in TIR.
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Tir
import Lyric.Tir as TirT
import Lyric.ContractElaborator
import Lyric.Iface

/// What type conversion needs beyond the type: the checker's table for
/// extern types, and the binders of the generic parameters in scope.  A
/// `TyParam`'s owner is the checker's binder key (D337); `ownerSyms` maps it to
/// the declaring symbol and `ownerParams` to the parameter names in
/// declaration order, which is the parameter's index.  `selfIface` is the
/// interface whose body is being converted, for `Self`.
pub record TyConvCtx {
  tbl: SymbolTable
  ownerSyms: Map[String, SymbolId]
  ownerParams: Map[String, List[String]]
  selfIface: Option[SymbolId]
  /// The union and enum case symbols of the table by `SymbolId`, filled on first use
  /// (`loadCases`); `casesLoaded` is a one-element flag.
  cases: Map[Int, Symbol] = newMap()
  casesLoaded: List[Bool] = newList()
  /// The defaults of the packages of the build checked before this one (D482), for a call
  /// that leaves out an argument whose default another package declares.
  dep: DepDefaults = newDepDefaults()
  /// The interfaces of `dep` read so far, by package, in this table's numbering.
  depRead: Map[String, Iface] = newMap()
}

pub func newTyConvCtx(tbl: in SymbolTable): TyConvCtx {
  TyConvCtx(tbl = tbl, ownerSyms = newMap(), ownerParams = newMap(), selfIface = None)
}

/// A context whose calls read cross-package defaults from `dep`.
pub func newTyConvCtxWith(tbl: in SymbolTable, dep: in DepDefaults): TyConvCtx {
  TyConvCtx(tbl = tbl, ownerSyms = newMap(), ownerParams = newMap(), selfIface = None, dep = dep)
}

/// Register the binder `key`: declared by `sym` with parameters `names`.
pub func tyConvBind(ctx: in TyConvCtx, key: in String, sym: in SymbolId, names: in List[String]): Unit {
  if ctx.ownerSyms.containsKey(key) {
    ctx.ownerSyms.remove(key)
    ctx.ownerParams.remove(key)
  }
  ctx.ownerSyms.add(key, sym)
  ctx.ownerParams.add(key, names)
}

/// The I0002 message for a type that cannot be converted.
func i0002Type(what: in String, t: in Type): String {
  "I0002: the checker gave no usable type for " + what + ": " + renderType(t)
}

func primOf(p: in PrimType): Ty {
  match p {
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
    case PtNever -> TirT.TNever
  }
}

func convList(ctx: in TyConvCtx, ts: in List[Type]): Result[List[Ty], String] {
  val res: List[Ty] = newList()
  for t in ts {
    match tyOfType(ctx, t) {
      case Ok(v) -> res.add(v)
      case Err(e) -> return Err(error = e)
    }
  }
  Ok(value = res)
}

func paramIndex(ctx: in TyConvCtx, name: in String, owner: in String): Option[Int] {
  match mapGet(ctx.ownerParams, owner) {
    case Some(names) -> {
      var i = 0
      while i < names.count {
        if names[i] == name {
          return Some(value = i)
        }
        i = i + 1
      }
      None
    }
    case None -> None
  }
}

/// The `Lyric.Tir` type of the checker's `t`, or the I0002 message saying why
/// it has none: a `TyError`, a `TyInfer` the call did not solve, or a
/// `TyParam` whose binder the builder has not registered.
pub func tyOfType(ctx: in TyConvCtx, t: in Type): Result[Ty, String] {
  match t {
    case TyPrim(p) -> Ok(value = primOf(p))
    case TyTuple(elems) -> match convList(ctx, elems) {
      case Ok(xs) -> Ok(value = TirT.TTuple(elems = xs))
      case Err(e) -> Err(error = e)
    }
    case TyNullable(inner) -> match tyOfType(ctx, inner) {
      case Ok(x) -> Ok(value = TirT.TNullable(inner = x))
      case Err(e) -> Err(error = e)
    }
    // The checker's function type has no parameter modes (D360), so each is `in`.
    case TyFunction(params, ret, isAsync) -> {
      val ps: List[TParamTy] = newList()
      for p in params {
        match tyOfType(ctx, p) {
          case Ok(x) -> ps.add(TParamTy(mode = TMIn, ty = x))
          case Err(e) -> return Err(error = e)
        }
      }
      match tyOfType(ctx, ret) {
        case Ok(r) -> Ok(value = TFunc(params = ps, ret = r, isAsync = isAsync))
        case Err(e) -> Err(error = e)
      }
    }
    case TyArray(size, element, sizeVar) -> match tyOfType(ctx, element) {
      case Err(e) -> Err(error = e)
      case Ok(el) -> match size {
        case Some(n) -> Ok(
          value = TirT.TArray(
            len = ALKnown(n = n),
            element = el
          )
        )
        case None -> match sizeVar {
          case None -> Ok(
            value = TirT.TArray(
              len = ALUnsized,
              element = el
            )
          )
          case Some(sv) -> match sv {
            case TyParam(name, owner) -> match mapGet(ctx.ownerSyms, owner) {
              case Some(osym) -> match paramIndex(ctx, name, owner) {
                case Some(i) -> Ok(
                  value = TirT.TArray(
                    len = ALParam(
                      owner = osym,
                      index = i
                    ),
                    element = el
                  )
                )
                case None -> Err(
                  error = i0002Type(
                    "an array length parameter",
                    sv
                  )
                )
              }
              case None -> Err(
                error = i0002Type(
                  "an array length parameter",
                  sv
                )
              )
            }
            case _ -> Err(
              error = i0002Type(
                "an array length",
                sv
              )
            )
          }
        }
      }
    }
    case TySlice(element) -> match tyOfType(ctx, element) {
      case Ok(x) -> Ok(value = TirT.TSlice(element = x))
      case Err(e) -> Err(error = e)
    }
    case TyUser(id, _, args) -> match convList(ctx, args) {
      case Err(e) -> Err(error = e)
      case Ok(xs) -> match symTableExternDeclOf(ctx.tbl, id) {
        case Some(decl) -> Ok(
          value = TExtern(
            host = HostTypeRef(
              name = decl.clrName,
              args = xs
            )
          )
        )
        case None -> Ok(value = TNamed(sym = id, args = xs))
      }
    }
    case TyRefined(underlying, lo, hi, hiInclusive, _) -> match tyOfType(ctx, underlying) {
      case Ok(x) -> Ok(
        value = TirT.TRefined(
          underlying = x,
          lo = lo,
          hi = hi,
          hiInclusive = hiInclusive
        )
      )
      case Err(e) -> Err(error = e)
    }
    case TySelf -> match ctx.selfIface {
      case Some(i) -> Ok(value = tySelfOf(i))
      case None -> Err(error = i0002Type("`Self` outside an interface", t))
    }
    case TyLen(n) -> Ok(value = TLen(n = n))
    case TyParam(name, owner) -> match mapGet(ctx.ownerSyms, owner) {
      case None -> Err(error = i0002Type("a type parameter with no registered binder", t))
      case Some(osym) -> match paramIndex(ctx, name, owner) {
        case Some(i) -> Ok(value = TParam(owner = osym, index = i))
        case None -> Err(
          error = i0002Type(
            "a type parameter its binder does not declare",
            t
          )
        )
      }
    }
    case TyInfer(_) -> Err(error = i0002Type("an unsolved inference variable", t))
    case TyError(_) -> Err(error = i0002Type("an expression the checker could not type", t))
    case TyException -> Ok(value = TException)
  }
}

/// The declaration a name expression that is not a local resolved to (D368).
pub func refSite(ctx: in TyConvCtx, node: in Int): Option[RefSite] {
  mapGet(ctx.tbl.refByNode, node)
}

/// The type the checker recorded for the pattern numbered `node`, as `Ty` (D369).
pub func patTy(ctx: in TyConvCtx, node: in Int): Result[Ty, String] {
  match mapGet(ctx.tbl.patTypes, node) {
    case None -> Err(error = "I0002: the checker recorded no type for pattern node #" + toString(node))
    case Some(t) -> tyOfType(ctx, t)
  }
}

/// The case or record symbol a pattern resolved to (D369).
pub func patSym(ctx: in TyConvCtx, node: in Int): Option[SymbolId] {
  mapGet(ctx.tbl.patSymByNode, node)
}

/// Whether the checker bound this `PBinding` as a local (D369).
pub func patIsBinding(ctx: in TyConvCtx, node: in Int): Bool {
  ctx.tbl.patBindingNodes.containsKey(node)
}

/// The index of the record field `name`, for a `FieldRef` (D369).
pub func recordFieldPos(ctx: in TyConvCtx, rec: in SymbolId, name: in String): Option[Int] {
  recordFieldIndex(ctx.tbl, rec, name)
}

/// Whether the checker proved a `match` covers every value (D369); `None` when
/// it recorded no verdict.
pub func matchProved(ctx: in TyConvCtx, node: in Int): Option[Bool] {
  mapGet(ctx.tbl.matchExhaustive, node)
}

/// The type the checker recorded for the expression numbered `node`, as `Ty`,
/// or the I0002 message: no entry (the checker never typed the node) or an
/// entry with no `Ty`.
pub func exprTy(ctx: in TyConvCtx, node: in Int): Result[Ty, String] {
  match mapGet(ctx.tbl.exprTypes, node) {
    case None -> Err(error = "I0002: the checker recorded no type for expression node #" + toString(node))
    case Some(t) -> tyOfType(ctx, t)
  }
}

/// The nodes of `exprIds` with no usable recorded type, as I0002 messages, in
/// the order given.  The census the `--verify-ir` flag reports.
pub func exprTypeCensus(ctx: in TyConvCtx, exprIds: in List[Int]): List[String] {
  val res: List[String] = newList()
  for id in exprIds {
    match exprTy(ctx, id) {
      case Ok(_) -> ()
      case Err(e) -> res.add(e)
    }
  }
  res
}

/// Every expression node id of `file`, in traversal order.
pub func exprNodeIds(file: in SourceFile): List[Int] {
  val ids: List[Int] = newList()
  mapFileNodes(file, { e: Expr -> ids.add(e.nodeId); e }, { s: Statement -> s }, { p: Pattern -> p })
  ids
}

/// A call expression: its node id and where it is.
pub record CallSite {
  id: Int
  span: Span
  /// The callee as written: a path (`Pkg.f`, `Some`), a member (`.get`), or
  /// `<expr>` for a call through any other expression.
  callee: String
}

func calleeText(fn: in Expr): String {
  match fn.kind {
    case EPath(path) -> modulePathJoin(path.segments)
    case EMember(_, name) -> "." + name
    case ETypeApp(inner, _) -> calleeText(inner)
    case EParen(inner) -> calleeText(inner)
    case _ -> "<expr>"
  }
}

/// Every call expression of `file`, in traversal order.
pub func callSitesOf(file: in SourceFile): List[CallSite] {
  val sites: List[CallSite] = newList()
  mapFileNodes(
    file,
    { e: Expr ->
      match e.kind {
        case ECall(fn, _) -> sites.add(CallSite(id = e.nodeId, span = e.span, callee = calleeText(fn)))
        case _ -> ()
      }
      e
    },
    { s: Statement -> s },
    { p: Pattern -> p }
  )
  sites
}

/// Whether the checker recorded the callee of the call at `id`: a declared
/// one (`calleeByNode`), a built-in's name (`builtinByNode`, D362), a call
/// through a function value (`indirectByNode`, D364) or an extern member
/// (`externByNode`, D365).
pub func callCovered(ctx: in TyConvCtx, id: in Int): Bool {
  ctx.tbl.calleeByNode.containsKey(id) or ctx.tbl.builtinByNode.containsKey(id) or
    ctx.tbl.indirectByNode.containsKey(id) or
    ctx.tbl.externByNode.containsKey(id)
}

/// The calls of `calls` the checker recorded no resolved callee for
/// (`SymbolTable.calleeByNode`), as I0002 messages naming the call's position.
/// A call is covered by `callCovered`; interface and extern member calls are
/// counted until their route records a callee (D361).
pub func calleeCensus(ctx: in TyConvCtx, calls: in List[CallSite]): List[String] {
  val res: List[String] = newList()
  for c in calls {
    if not callCovered(ctx, c.id) {
      res.add(
        "I0002: the checker recorded no callee for the call at " + toString(c.span.startPos.line) + ":" +
          toString(c.span.startPos.column) +
          " (node #" +
          toString(c.id) +
          ") to " +
          c.callee
      )
    }
  }
  res
}

/// The callees of the uncovered calls with how many calls each has, most
/// frequent first, at most `limit` of them, as `name x count` lines: which
/// route to cover next (D361).
pub func calleeCensusByName(ctx: in TyConvCtx, calls: in List[CallSite], limit: in Int): List[String] {
  val counts: Map[String, Int] = newMap()
  for c in calls {
    if not callCovered(ctx, c.id) {
      val n = match mapGet(counts, c.callee) { case Some(k) -> k; case None -> 0 }
      if counts.containsKey(c.callee) {
        counts.remove(c.callee)
      }
      counts.add(c.callee, n + 1)
    }
  }
  val res: List[String] = newList()
  val taken: Map[String, Bool] = newMap()
  var round = 0
  while round < limit {
    var best = ""
    var bestN = 0
    for k in mapKeys(counts) {
      if not taken.containsKey(k) {
        val n = match mapGet(counts, k) { case Some(v) -> v; case None -> 0 }
        if n > bestN {
          best = k
          bestN = n
        }
      }
    }
    if bestN == 0 {
      return res
    }
    taken.add(best, true)
    res.add(best + " x " + toString(bestN))
    round = round + 1
  }
  res
}
