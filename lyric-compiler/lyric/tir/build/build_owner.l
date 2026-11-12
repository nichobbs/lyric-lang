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

/// The method call `e` instantiated: `site.sig` unchanged for a member with no generics.
pub func instantiateMethod(
  env: in BuildEnv, e: in Expr, site: in MethodCallSite, args: in List[CallArg]
): Option[MethodInst] {
  val sig = site.sig
  if sig.generics.count == 0 {
    // The checker leaves the owner's parameters out of the signature when the receiver's
    // arguments are the caller's own parameters; they are the receiver's type arguments.
    val none: List[Ty] = newList()
    val recvArgs = receiverTypeArgs(site.recvTy)
    if recvArgs.count == 0 or isSome(site.iface) {
      return Some(value = MethodInst(sig = sig, tyArgs = none))
    }
    val owned: List[Ty] = newList()
    for ta in recvArgs {
      match tyOfType(env.ctx, ta) {
        case Ok(t) -> owned.add(t)
        case Err(msg) -> {
          env.errors.add(msg)
          return None
        }
      }
    }
    return Some(value = MethodInst(sig = sig, tyArgs = owned))
  }
  val ownerN = ownerGenericCount(sig)
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
    val inferred = genericArgsFromCall(env, sig, rt, args)
    val recvArgs = receiverTypeArgs(site.recvTy)
    if ownerN > 0 and recvArgs.count != ownerN {
      val _ = uncoveredExpr(env, e, "a method call on a member of a generic impl")
      return None
    }
    var i = 0
    while i < inferred.count {
      checkerArgs.add(if i < ownerN { recvArgs[i] } else { inferred[i] })
      i = i + 1
    }
  }
  if checkerArgs.count != sig.generics.count {
    val _ = uncoveredExpr(env, e, "a generic call whose instantiation does not match the callee")
    return None
  }
  val tyArgs: List[Ty] = newList()
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
