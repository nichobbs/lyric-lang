//! build_owner.l - calls of a member of a generic type (docs/70 §6.2, D580).  A member's generic
//! space is the owner's parameters first and its own after (D579); a call instantiates all of
//! them: the owner's from the receiver's type arguments, the member's own from the call (the
//! checker's record, else inferred from the arguments and the result as a generic function's).
package Lyric.Tir.Build

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.Tir

/// A method call's callee signature with its generics substituted, and the type arguments in
/// the member's generic space (the owner's first).
pub record MethodInst {
  sig: ResolvedSignature
  tyArgs: List[Ty]
}

/// How many leading generics of `sig` are the owner's: the checker binds the owner's under the
/// owner's key and the member's own under `Owner.fn`, so an owner key has no dot.
func ownerGenericCount(sig: in ResolvedSignature): Int {
  var n = 0
  while n < sig.generics.count and n < sig.genericOwners.count and not sig.genericOwners[n].contains(".") {
    n = n + 1
  }
  n
}

/// The receiver's type arguments when it is an instance of a generic type.
func receiverTypeArgs(t: in Type): List[Type] {
  match t {
    case TyUser(_, _, targs) -> targs
    case _ -> newList()
  }
}

/// The receiver type's own `SymbolId` when it is a user type.
func receiverTypeId(t: in Type): Option[SymbolId] {
  match t {
    case TyUser(id, _, _) -> Some(value = id)
    case _ -> None
  }
}

/// A DefPath key is the owner's key, `::`, then the member's name; the `::` terminator keeps a
/// type whose name is a prefix of another's (`Box`, `BoxOf`) from matching the other's members.
/// Whether the callee `sym` is declared in the body of the receiver's type (a record's or a
/// protected type's member, whose owner parameters are the type's own), not in an `impl`.
func isBodyMemberOf(env: in BuildEnv, sym: in SymbolId, recvTy: in Type): Bool {
  val tid = match receiverTypeId(recvTy) { case Some(t) -> t; case None -> return false }
  val tk = match defPathKeyOf(env.ctx.tbl.interner, tid) { case Some(k) -> k; case None -> return false }
  match defPathKeyOf(env.ctx.tbl.interner, sym) {
    case Some(k) -> k.startsWith(tk + "::")
    case None -> false
  }
}

/// The method call `e` instantiated: the owner's arguments (the receiver's type arguments, for
/// a member declared in the type's body) then the member's own (the checker's record, else
/// inferred from the arguments and the result as a generic function's are).  The checker's
/// signature lists only the member's own generics for a concrete receiver and none for a
/// receiver typed over the caller's own parameters, so the owner's are never read from it.
pub func instantiateMethod(
  env: in BuildEnv,
  e: in Expr,
  sym: in SymbolId,
  site: in MethodCallSite,
  args: in List[CallArg],
): Option[MethodInst] {
  val sig = site.sig
  val recvArgs = receiverTypeArgs(site.recvTy)
  val owned: List[Ty] = newList()
  if recvArgs.count > 0 and not isSome(site.iface) {
    if not isBodyMemberOf(env, sym, site.recvTy) {
      val _ = uncoveredExpr(env, e, "a method call on a member of a generic impl")
      return None
    }
    for ta in recvArgs {
      match tyOfType(env.ctx, ta) {
        case Ok(t) -> owned.add(t)
        case Err(msg) -> {
          env.errors.add(msg)
          return None
        }
      }
    }
  }
  if sig.generics.count == 0 {
    return Some(value = MethodInst(sig = sig, tyArgs = owned))
  }
  var checkerArgs: List[Type] = newList()
  var recorded = false
  match mapGet(env.ctx.tbl.genericArgsByNode, e.nodeId) {
    case Some(ts) -> if ts.count == sig.generics.count { checkerArgs = ts; recorded = true }
    case None -> ()
  }
  if not recorded {
    val rt = match mapGet(env.ctx.tbl.exprTypes, e.nodeId) {
      case Some(t) -> t
      case None -> {
        val _ = uncoveredExpr(env, e, "a generic call with no recorded instantiation")
        return None
      }
    }
    checkerArgs = genericArgsFromCall(env, sig, rt, args)
  }
  if checkerArgs.count != sig.generics.count {
    val _ = uncoveredExpr(env, e, "a generic call whose instantiation does not match the callee")
    return None
  }
  val tyArgs: List[Ty] = newList()
  for t in owned {
    tyArgs.add(t)
  }
  for ta in checkerArgs {
    match tyOfType(env.ctx, ta) {
      case Ok(t) -> tyArgs.add(t)
      case Err(msg) -> {
        env.errors.add(msg)
        return None
      }
    }
  }
  val ps: List[ResolvedParam] = newList()
  for p in sig.params {
    ps.add(p.copy(ty = substituteTyParamsOwned(p.ty, sig.generics, sig.genericOwners, checkerArgs)))
  }
  Some(value = MethodInst(sig = sig.copy(params = ps), tyArgs = tyArgs))
}
