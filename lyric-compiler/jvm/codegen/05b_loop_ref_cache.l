//! jvm/codegen/05b_loop_ref_cache.l - Jvm.Codegen: loop-scoped caching of an
//! `out`/`inout` place (#8371, D183).
//!
//! An `out`/`inout` parameter is a `Lyric$Ref$<K>` place reference, and the
//! callee reads it through `get()` at each use and writes it through `set(v)`.
//! A callee called with several kinds of place sees several receiver classes at
//! those call sites, so they are megamorphic and the JIT cannot inline them.
//!
//! A loop whose compiled body cannot reach the place by any other path can
//! keep the place's value in the parameter's value slot for the whole loop:
//! one `get()` before the loop, one `set(v)` after it, and the reads and
//! writes in between become plain local loads and stores.  "Cannot reach the
//! place" is decided on the loop's bytecode, not its source, so an overloaded
//! operator or an inlined helper is seen for what it is.  The body may hold
//! only local-slot loads and stores, constants, non-trapping arithmetic and
//! comparisons, conversions and branches that stay inside the loop, and it
//! may touch exactly one place reference.  A call, a field access, an
//! allocation, an array access, a division, a cast, a `return`, a `throw` or
//! a jump out of the loop leaves the loop as it was: the first group is how a
//! second path to the place, an aliasing write or a closure would show up,
//! and the rest can raise an exception, which would skip the write back and
//! lose a write made before a panic (D183).

package Jvm.Codegen

import Std.Core
import Std.Collections
import Std.String
import Jvm.Lowering

func loopCacheStoreSlot(i: in LInsn): Option[Int] {
  match i {
    case LIstore(s) -> Some(value = s)
    case LLstore(s) -> Some(value = s)
    case LDstore(s) -> Some(value = s)
    case LFstore(s) -> Some(value = s)
    case LAstore(s) -> Some(value = s)
    case LAstoreAs(s, _) -> Some(value = s)
    case _ -> None
  }
}

func loopCacheLoadSlot(i: in LInsn): Option[Int] {
  match i {
    case LIload(s) -> Some(value = s)
    case LLload(s) -> Some(value = s)
    case LDload(s) -> Some(value = s)
    case LFload(s) -> Some(value = s)
    case LAload(s) -> Some(value = s)
    case _ -> None
  }
}

func loopCacheIsRefCall(i: in LInsn, method: in String): Bool {
  match i {
    case LInvokeinterface(owner, name, _, _, _) -> isRefIfaceName(owner) and name == method
    case _ -> false
  }
}

func loopCacheIsBinding(ctx: in FuncCtx, valueSlot: in Int, refSlot: in Int): Bool {
  match mapGet(ctx.refParamSlot, valueSlot) {
    case Some(s) -> s == refSlot
    case None -> false
  }
}

func loopCacheHasLabel(labels: in List[String], l: in String): Bool {
  var i = 0
  while i < labels.count {
    if labels[i] == l {
      return true
    }
    i = i + 1
  }
  false
}

// The branch target of `i`, when it is a plain branch.
func loopCacheTarget(i: in LInsn): Option[String] {
  match i {
    case LGoto(l) -> Some(value = l)
    case LIfeq(l) -> Some(value = l)
    case LIfne(l) -> Some(value = l)
    case LIflt(l) -> Some(value = l)
    case LIfge(l) -> Some(value = l)
    case LIfgt(l) -> Some(value = l)
    case LIfle(l) -> Some(value = l)
    case LIfnull(l) -> Some(value = l)
    case LIfnonnull(l) -> Some(value = l)
    case LIfIcmpeq(l) -> Some(value = l)
    case LIfIcmpne(l) -> Some(value = l)
    case LIfIcmplt(l) -> Some(value = l)
    case LIfIcmpge(l) -> Some(value = l)
    case LIfIcmpgt(l) -> Some(value = l)
    case LIfIcmple(l) -> Some(value = l)
    case LIfAcmpeq(l) -> Some(value = l)
    case LIfAcmpne(l) -> Some(value = l)
    case _ -> None
  }
}

// True for an instruction that can neither reach a place nor leave the loop
// other than by a branch (checked separately) or an exception.
func loopCacheSafeInsn(i: in LInsn): Bool {
  match i {
    case LLabel(_) -> true
    case LLineMarker(_, _) -> true
    case LNop -> true
    case LIconst(_) -> true
    case LLconst(_) -> true
    case LFconst(_) -> true
    case LDconst(_) -> true
    case LPushString(_) -> true
    case LAconstNull -> true
    case LIload(_) -> true
    case LLload(_) -> true
    case LDload(_) -> true
    case LFload(_) -> true
    case LAload(_) -> true
    case LIstore(_) -> true
    case LLstore(_) -> true
    case LDstore(_) -> true
    case LFstore(_) -> true
    case LAstore(_) -> true
    case LAstoreAs(_, _) -> true
    case LPop -> true
    case LPop2 -> true
    case LDup -> true
    case LDup_x1 -> true
    case LDup_x2 -> true
    case LIadd -> true
    case LIsub -> true
    case LImul -> true
    case LIneg -> true
    case LIinc(_, _) -> true
    case LI2l -> true
    case LI2d -> true
    case LL2i -> true
    case LLadd -> true
    case LLsub -> true
    case LLmul -> true
    case LDadd -> true
    case LDsub -> true
    case LDmul -> true
    case LDdiv -> true
    case LFadd -> true
    case LFsub -> true
    case LFmul -> true
    case LFdiv -> true
    case LFrem -> true
    case LFneg -> true
    case LIand -> true
    case LIor -> true
    case LIxor -> true
    case LIshl -> true
    case LIshr -> true
    case LIushr -> true
    case LLneg -> true
    case LLand -> true
    case LLor -> true
    case LLxor -> true
    case LLshl -> true
    case LLshr -> true
    case LLushr -> true
    case LLcmp -> true
    case LDrem -> true
    case LDneg -> true
    case LFcmpl -> true
    case LFcmpg -> true
    case LDcmpl -> true
    case LDcmpg -> true
    case LL2f -> true
    case LL2d -> true
    case LI2f -> true
    case LI2b -> true
    case LI2c -> true
    case LI2s -> true
    case LF2i -> true
    case LF2l -> true
    case LF2d -> true
    case LD2i -> true
    case LD2l -> true
    case LD2f -> true
    case LInstanceof(_) -> true
    case _ -> false
  }
}

// Append the loop in `loopInsns` (which begins with the label `loopL` and ends
// with the label `afterL`) to `insns`, caching the one place reference it uses
// in the parameter's value slot when the loop's bytecode allows it (see the
// module header); otherwise append it unchanged.
pub func appendLoopWithRefCache(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  loopInsns: in List[LInsn],
  loopL: in String,
  afterL: in String,
): Unit {
  if tryAppendCachedLoop(ctx, insns, loopInsns, loopL, afterL) {
    return
  }
  var k = 0
  while k < loopInsns.count {
    insns.add(loopInsns[k])
    k = k + 1
  }
}

func tryAppendCachedLoop(
  ctx: in FuncCtx,
  insns: in List[LInsn],
  loopInsns: in List[LInsn],
  loopL: in String,
  afterL: in String,
): Bool {
  val n = loopInsns.count
  val drop: List[Bool] = newList()
  var k = 0
  while k < n {
    drop.add(false)
    k = k + 1
  }
  var refSlot = -1
  val refresh: List[LInsn] = newList()
  val flush: List[LInsn] = newList()
  var i = 0
  while i < n {
    match loopInsns[i] {
      case LAload(s) -> {
        if i + 1 < n and loopCacheIsRefCall(loopInsns[i + 1], "get") {
          // aload ref; invokeinterface get; [iconst 255; iand] [checkcast];
          // <store value slot>
          var j = i + 2
          var valueSlot = -1
          var scanning = true
          while scanning and j < n {
            match loopCacheStoreSlot(loopInsns[j]) {
              case Some(v) -> {
                valueSlot = v
                scanning = false
              }
              case None -> {
                match loopInsns[j] {
                  case LIconst(_) -> { j = j + 1 }
                  case LIand -> { j = j + 1 }
                  case LCheckcast(_) -> { j = j + 1 }
                  case _ -> { scanning = false }
                }
              }
            }
          }
          if valueSlot < 0 or not loopCacheIsBinding(ctx, valueSlot, s) {
            return false
          }
          if refSlot >= 0 and refSlot != s {
            return false
          }
          refSlot = s
          if refresh.count == 0 {
            var m = i
            while m <= j {
              refresh.add(loopInsns[m])
              m = m + 1
            }
          }
          var m2 = i
          while m2 <= j {
            drop[m2] = true
            m2 = m2 + 1
          }
          i = j + 1
        } else if i + 2 < n and loopCacheIsRefCall(loopInsns[i + 2], "set") {
          // aload ref; <load value slot>; invokeinterface set
          val valueSlot = match loopCacheLoadSlot(loopInsns[i + 1]) {
            case Some(v) -> v
            case None -> -1
          }
          if valueSlot < 0 or not loopCacheIsBinding(ctx, valueSlot, s) {
            return false
          }
          if refSlot >= 0 and refSlot != s {
            return false
          }
          refSlot = s
          if flush.count == 0 {
            flush.add(loopInsns[i])
            flush.add(loopInsns[i + 1])
            flush.add(loopInsns[i + 2])
          }
          drop[i] = true
          drop[i + 1] = true
          drop[i + 2] = true
          i = i + 3
        } else {
          i = i + 1
        }
      }
      case _ -> { i = i + 1 }
    }
  }
  if refSlot < 0 {
    return false
  }
  val kept: List[LInsn] = newList()
  val labels: List[String] = newList()
  var q = 0
  while q < n {
    if not drop[q] {
      val ins = loopInsns[q]
      if not loopCacheSafeInsn(ins) {
        match loopCacheTarget(ins) {
          case Some(_) -> ()
          case None -> {
            return false
          }
        }
      }
      match ins {
        case LLabel(name) -> labels.add(name)
        case _ -> ()
      }
      kept.add(ins)
    }
    q = q + 1
  }
  // Every branch stays inside the loop, and the exit label is a branch target
  // (else the code after it would be unreachable and carry no frame).
  var exitReached = false
  var r = 0
  while r < kept.count {
    match loopCacheTarget(kept[r]) {
      case Some(t) -> {
        if not loopCacheHasLabel(labels, t) {
          return false
        }
        if t == afterL {
          exitReached = true
        }
      }
      case None -> ()
    }
    r = r + 1
  }
  if not exitReached or not loopCacheHasLabel(labels, loopL) {
    return false
  }
  var e = 0
  while e < refresh.count {
    insns.add(refresh[e])
    e = e + 1
  }
  var a = 0
  while a < kept.count {
    insns.add(kept[a])
    a = a + 1
  }
  if flush.count > 0 {
    var f = 0
    while f < flush.count {
      insns.add(flush[f])
      f = f + 1
    }
  }
  true
}
