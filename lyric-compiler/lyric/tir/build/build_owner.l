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
  /// The receiver's type under the instantiation, for a dot-named function called as a method
  /// (its first parameter); `None` for a member declared in a type's body.
  recvTy: Option[Ty] = None
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

/// The part of a member's DefPath key before its own name segment: the type or `impl` it belongs to.
func memberOwnerKey(key: in String): String {
  var cut = -1
  var i = 0
  while i + 1 < key.length {
    if key.substring(i, 2) == "::" {
      cut = i
    }
    i = i + 1
  }
  if cut < 0 {
    key
  } else {
    key.substring(0, cut)
  }
}

/// The first position at or after `from` where `sub` occurs in `s`, or -1.
func findSub(s: in String, sub: in String, from: in Int): Int {
  var i = from
  while i + sub.length <= s.length {
    if s.substring(i, sub.length) == sub {
      return i
    }
    i = i + 1
  }
  -1
}

/// The type arguments an `impl`'s target is written with, from its DefPath key (`Pkg::Box[T,U]::$impl(I)`
/// is `T,U`): None when the key's target has no argument list.
func implTargetNames(ownerKey: in String): Option[List[String]] {
  val open = findSub(ownerKey, "[", 0)
  val close = findSub(ownerKey, "]::$impl(", 0)
  if open < 0 or close < open {
    return None
  }
  val names: List[String] = newList()
  var cur = ""
  var i = open + 1
  while i < close {
    val ch = ownerKey.substring(i, 1)
    if ch == "," {
      names.add(cur)
      cur = ""
    } else if ch != " " {
      cur = cur + ch
    }
    i = i + 1
  }
  names.add(cur)
  Some(value = names)
}

/// Whether the callee `sym` is a member of the same `impl` as the member being built (a bare call of a
/// sibling, or a call on `self`'s own type) and the impl's target is written over exactly the impl's own
/// parameters in the order it declares them, so the receiver's type arguments are the impl's, position
/// by position.
func isSiblingImplMember(env: in BuildEnv, sym: in SymbolId): Bool {
  if env.symOverride.count == 0 or env.memberOwner.count == 0 {
    return false
  }
  val here = match defPathKeyOf(env.ctx.tbl.interner, env.symOverride[0]) {
    case Some(k) -> memberOwnerKey(k)
    case None -> return false
  }
  val there = match defPathKeyOf(env.ctx.tbl.interner, sym) {
    case Some(k) -> memberOwnerKey(k)
    case None -> return false
  }
  if here != there or findSub(here, "::$impl(", 0) < 0 {
    return false
  }
  match implTargetNames(here) {
    case Some(names) -> {
      val declared = env.memberOwner[0].names
      if names.count != declared.count {
        return false
      }
      var i = 0
      while i < names.count {
        if names[i] != declared[i] {
          return false
        }
        i = i + 1
      }
      true
    }
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
    if not (isBodyMemberOf(env, sym, site.recvTy) or isSiblingImplMember(env, sym)) {
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
    checkerArgs = genericArgsFromCall(env, sig, rt, args, None)
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

/// A call `recv.m(args)` of a dot-named generic function `Type.m` (a value-generic record's
/// methods, D173) instantiated: its generics are read off the receiver's type (`recvActual`, the
/// receiver expression's type) and the arguments as a call of the function with the receiver
/// first reads them.  The signature returned has the receiver dropped and the generics
/// substituted; `recvTy` is the substituted receiver parameter.
pub func instantiateDotted(
  env: in BuildEnv,
  e: in Expr,
  sym: in SymbolId,
  full: in ResolvedSignature,
  recvActual: in Type,
  args: in List[CallArg],
): Option[MethodInst] {
  if full.params.count == 0 {
    val _ = uncoveredExpr(env, e, "a dot-named function called as a method without a receiver parameter")
    return None
  }
  var checkerArgs: List[Type] = newList()
  if full.generics.count > 0 {
    val rt = match mapGet(env.ctx.tbl.exprTypes, e.nodeId) {
      case Some(t) -> t
      case None -> {
        val _ = uncoveredExpr(env, e, "a generic call with no recorded instantiation")
        return None
      }
    }
    checkerArgs = genericArgsFromCall(env, full, rt, args, Some(value = recvActual))
    if checkerArgs.count != full.generics.count {
      val _ = uncoveredExpr(env, e, "a generic call whose instantiation does not match the callee")
      return None
    }
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
  var recvParamTy: Type = full.params[0].ty
  var i = 0
  while i < full.params.count {
    val pty = if full.generics.count > 0 {
      substituteTyParamsOwned(full.params[i].ty, full.generics, full.genericOwners, checkerArgs)
    } else {
      full.params[i].ty
    }
    if i == 0 {
      recvParamTy = pty
    } else {
      ps.add(full.params[i].copy(ty = pty))
    }
    i = i + 1
  }
  val recvTy = match tyOfType(env.ctx, recvParamTy) {
    case Ok(t) -> t
    case Err(msg) -> {
      env.errors.add(msg)
      return None
    }
  }
  Some(
    value = MethodInst(
      sig = full.copy(params = ps, recvMode = Some(value = full.params[0].mode)),
      tyArgs = tyArgs,
      recvTy = Some(value = recvTy)
    )
  )
}
