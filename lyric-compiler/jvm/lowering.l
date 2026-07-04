//! jvm/lowering.l — Stage B3 JVM type descriptors and instruction lowering.
//!
//! Provides:
//!   • `JvmType` — typed representation of JVM field/return types.
//!   • `LInsn` — high-level instruction union; `lowerInsn` resolves pool refs.
//!   • `LField` / `LFunc` / `LRecord` — typed class/method/field descriptors.
//!   • `lowerFunc` — lowers an LFunc to a MethodInfo with a Code attribute.
//!   • `lowerRecord` — lowers an LRecord to a ClassFile with a synthesised ctor.
//!   • `LPTestModule` (B126) — test-module package item; see `Jvm.TestEngine`.
package Jvm.Lowering

import Std.Core
import Std.Collections
import Std.File as File
import Std.Environment as Env
import Std.ProcessCapture as ProcessCapture
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.TestEngine

// ── JvmType ───────────────────────────────────────────────────────────────────
pub union JvmType {
  case JBoolean
  case JByte
  case JChar
  case JShort
  case JInt
  case JLong
  case JFloat
  case JDouble
  case JVoid
  case JRef(className: String)
  case JArray(elem: JvmType)
}

pub func typeDescriptor(t: in JvmType): String {
  match t {
    case JBoolean -> "Z"
    case JByte -> "B"
    case JChar -> "C"
    case JShort -> "S"
    case JInt -> "I"
    case JLong -> "J"
    case JFloat -> "F"
    case JDouble -> "D"
    case JVoid -> "V"
    case JRef(cls) -> "L" + cls + ";"
    case JArray(el) -> "[" + typeDescriptor(el)
  }
}

pub func buildDescriptor(params: in List[JvmType], ret: in JvmType): String {
  var desc = "("
  var i = 0
  while i < params.count {
    desc = desc + typeDescriptor(params[i])
    i = i + 1
  }
  desc = desc + ")" + typeDescriptor(ret)
  desc
}

// ── LInsn ─────────────────────────────────────────────────────────────────────
pub union LInsn {
  case LLabel(name: String)
  case LNop
  case LReturn
  case LIreturn
  case LLreturn
  case LDreturn
  case LAreturn
  case LAthrow

  case LIconst(v: Int)
  case LLconst(v: Long)
  case LFconst(v: Double)
  case LDconst(v: Double)
  case LPushString(s: String)

  case LIload(slot: Int)
  case LLload(slot: Int)
  case LDload(slot: Int)
  case LAload(slot: Int)
  case LIstore(slot: Int)
  case LLstore(slot: Int)
  case LDstore(slot: Int)
  case LAstore(slot: Int)
  case LAstoreAs(slot: Int, className: String)

  case LPop
  case LPop2
  case LDup
  case LDup_x1
  case LDup_x2

  case LIadd
  case LIsub
  case LImul
  case LIdiv
  case LIrem
  case LIneg
  case LIinc(slot: Int, delta: Int)
  case LI2l
  case LI2d
  case LL2i

  case LLadd
  case LLsub
  case LLmul
  case LLdiv

  case LDadd
  case LDsub
  case LDmul
  case LDdiv

  case LGoto(label: String)
  case LIfeq(label: String)
  case LIfnull(label: String)
  case LIfnonnull(label: String)
  case LIfne(label: String)
  case LIflt(label: String)
  case LIfge(label: String)
  case LIfgt(label: String)
  case LIfle(label: String)
  case LIfIcmpeq(label: String)
  case LIfIcmpne(label: String)
  case LIfIcmplt(label: String)
  case LIfIcmpge(label: String)
  case LIfIcmpgt(label: String)
  case LIfIcmple(label: String)
  case LIfAcmpeq(label: String)
  case LIfAcmpne(label: String)

  case LFload(slot: Int)
  case LFstore(slot: Int)
  case LFreturn
  case LFadd
  case LFsub
  case LFmul
  case LFdiv
  case LFrem
  case LFneg

  case LIand
  case LIor
  case LIxor
  case LIshl
  case LIshr
  case LIushr

  case LLneg
  case LLrem
  case LLand
  case LLor
  case LLxor
  case LLshl
  case LLshr
  case LLushr
  case LLcmp

  case LDrem
  case LDneg
  case LFcmpl
  case LFcmpg
  case LDcmpl
  case LDcmpg

  case LL2f
  case LL2d
  case LI2f
  case LI2b
  case LI2c
  case LI2s
  case LF2i
  case LF2l
  case LF2d
  case LD2i
  case LD2l
  case LD2f

  case LGetfield(owner: String, name: String, t: JvmType)
  case LPutfield(owner: String, name: String, t: JvmType)
  case LGetstatic(owner: String, name: String, t: JvmType)
  case LPutstatic(owner: String, name: String, t: JvmType)

  case LInvokevirtual(owner: String, name: String, params: List[JvmType], ret: JvmType)
  case LInvokespecial(owner: String, name: String, params: List[JvmType], ret: JvmType)
  case LInvokestatic(owner: String, name: String, params: List[JvmType], ret: JvmType)
  case LInvokeinterface(owner: String, name: String, params: List[JvmType], ret: JvmType, argCount: Int)

  case LNew(className: String)
  case LCheckcast(className: String)
  case LInstanceof(className: String)
  case LAconstNull

  case LAnewarray(className: String)
  case LNewarray(typeCode: Int)
  case LArraylength

  case LTableswitch(low: Int, high: Int, defaultLabel: String, caseLabels: List[String])
  case LLookupswitch(defaultLabel: String, pairs: List[SwitchPair])

  // Meta-insn: declares an exception table entry.  Produces no bytecode; lowerFunc
  // collects these and emits them in the Code attribute's exception_table.
  // catchClass = "" means catch-all (catch_type=0 in the class file).
  case LTryCatch(startLabel: String, endLabel: String, handlerLabel: String, catchClass: String)

  // Boxing convenience insns: expand to invokestatic <Wrapper>.valueOf(prim)Wrapper.
  case LBoxInt
  case LBoxLong
  case LBoxFloat
  case LBoxDouble
  case LBoxBool
  case LBoxByte
  case LBoxChar
  case LBoxShort

  // Unboxing convenience insns: expand to invokevirtual <Wrapper>.<prim>Value()prim.
  case LUnboxInt
  case LUnboxLong
  case LUnboxFloat
  case LUnboxDouble
  case LUnboxBool
  case LUnboxByte
  case LUnboxChar
  case LUnboxShort

  case LIaload
  case LLaload
  case LFaload
  case LDaload
  case LAaload
  case LBaload
  case LCaload
  case LSaload

  case LIastore
  case LLastore
  case LFastore
  case LDastore
  case LAastore
  case LBastore
  case LCastore
  case LSastore

  // Generator yield meta-insn: the preceding instructions must have left
  // one value on the stack.  `lowerInsn` panics on this; use only inside
  // `lowerAsyncGenerator`'s `runBody` emission (handled specially there).
  case LYield
  // ── Type helpers (no OR patterns) ────────────────────────────────────────────
  // Returns 2 for double-width types (long, double), 1 for all others.
}

pub func fieldSlotSize(t: in JvmType): Int {
  match t {
    case JLong -> 2
    case JDouble -> 2
    case JBoolean -> 1
    case JByte -> 1
    case JChar -> 1
    case JShort -> 1
    case JInt -> 1
    case JFloat -> 1
    case JVoid -> 0
    case JRef(_) -> 1
    case JArray(_) -> 1
  }
}

// Sum of slot sizes for a list of JvmType parameters.
pub func slotSum(ps: in List[JvmType]): Int {
  var s = 0
  var i = 0
  while i < ps.count {
    s = s + fieldSlotSize(ps[i])
    i = i + 1
  }
  s
}

pub func lowerInsn(insn: in LInsn, asm: in MethodAssembler): Unit {
  match insn {
    case LLabel(n) -> {
      emitLabel(asm, n)
      resetStack(asm)
    }
    case LNop -> emitNop(asm)
    case LReturn -> emitReturn(asm)
    case LIreturn -> {
      emitIreturn(asm)
      trackStack(asm, -1)
    }
    case LLreturn -> {
      emitLreturn(asm)
      trackStack(asm, -2)
    }
    case LDreturn -> {
      emitDreturn(asm)
      trackStack(asm, -2)
    }
    case LAreturn -> {
      emitAreturn(asm)
      trackStack(asm, -1)
    }
    case LAthrow -> {
      emitAthrow(asm)
      trackStack(asm, -1)
    }

    case LIconst(v) -> {
      emitPushInt(asm, v)
      trackStack(asm, 1)
    }
    case LLconst(v) -> {
      emitPushLong(asm, v)
      trackStack(asm, 2)
    }
    case LFconst(v) -> {
      emitPushFloat(asm, v)
      trackStack(asm, 1)
    }
    case LDconst(v) -> {
      emitPushDouble(asm, v)
      trackStack(asm, 2)
    }
    case LPushString(s) -> {
      emitPushString(asm, s)
      trackStack(asm, 1)
    }

    case LIload(s) -> {
      emitIload(asm, s)
      trackStack(asm, 1)
    }
    case LLload(s) -> {
      emitLload(asm, s)
      trackStack(asm, 2)
    }
    case LDload(s) -> {
      emitDload(asm, s)
      trackStack(asm, 2)
    }
    case LAload(s) -> {
      emitAload(asm, s)
      trackStack(asm, 1)
    }
    case LIstore(s) -> {
      emitIstore(asm, s)
      trackStack(asm, -1)
    }
    case LLstore(s) -> {
      emitLstore(asm, s)
      trackStack(asm, -2)
    }
    case LDstore(s) -> {
      emitDstore(asm, s)
      trackStack(asm, -2)
    }
    case LAstore(s) -> {
      emitAstore(asm, s)
      trackStack(asm, -1)
    }
    case LAstoreAs(s, _cls) -> {
      emitAstore(asm, s)
      trackStack(asm, -1)
    }

    case LPop -> {
      emitPop(asm)
      trackStack(asm, -1)
    }
    case LPop2 -> {
      asm.insns.add(Nullary(op = 0x58))
      trackStack(asm, -2)
    }
    case LDup -> {
      emitDup(asm)
      trackStack(asm, 1)
    }
    case LDup_x1 -> {
      asm.insns.add(Nullary(op = 0x5A))
      trackStack(asm, 1)
    }
    case LDup_x2 -> {
      asm.insns.add(Nullary(op = 0x5B))
      trackStack(asm, 1)
    }

    case LIadd -> {
      emitIadd(asm)
      trackStack(asm, -1)
    }
    case LIsub -> {
      emitIsub(asm)
      trackStack(asm, -1)
    }
    case LImul -> {
      emitImul(asm)
      trackStack(asm, -1)
    }
    case LIdiv -> {
      emitIdiv(asm)
      trackStack(asm, -1)
    }
    case LIrem -> {
      emitIrem(asm)
      trackStack(asm, -1)
    }
    case LIneg -> emitIneg(asm)
    case LIinc(s, d) -> emitIinc(asm, s, d)
    case LI2l -> {
      emitI2l(asm)
      trackStack(asm, 1)
    }
    case LI2d -> {
      emitI2d(asm)
      trackStack(asm, 1)
    }
    case LL2i -> {
      emitL2i(asm)
      trackStack(asm, -1)
    }

    case LLadd -> {
      emitLadd(asm)
      trackStack(asm, -2)
    }
    case LLsub -> {
      emitLsub(asm)
      trackStack(asm, -2)
    }
    case LLmul -> {
      emitLmul(asm)
      trackStack(asm, -2)
    }
    case LLdiv -> {
      emitLdiv(asm)
      trackStack(asm, -2)
    }

    case LDadd -> {
      emitDadd(asm)
      trackStack(asm, -2)
    }
    case LDsub -> {
      emitDsub(asm)
      trackStack(asm, -2)
    }
    case LDmul -> {
      emitDmul(asm)
      trackStack(asm, -2)
    }
    case LDdiv -> {
      emitDdiv(asm)
      trackStack(asm, -2)
    }

    case LFload(s) -> {
      emitFload(asm, s)
      trackStack(asm, 1)
    }
    case LFstore(s) -> {
      emitFstore(asm, s)
      trackStack(asm, -1)
    }
    case LFreturn -> {
      emitFreturn(asm)
      trackStack(asm, -1)
    }
    case LFadd -> {
      emitFadd(asm)
      trackStack(asm, -1)
    }
    case LFsub -> {
      emitFsub(asm)
      trackStack(asm, -1)
    }
    case LFmul -> {
      emitFmul(asm)
      trackStack(asm, -1)
    }
    case LFdiv -> {
      emitFdiv(asm)
      trackStack(asm, -1)
    }
    case LFrem -> {
      emitFrem(asm)
      trackStack(asm, -1)
    }
    case LFneg -> emitFneg(asm)

    case LIand -> {
      emitIand(asm)
      trackStack(asm, -1)
    }
    case LIor -> {
      emitIor(asm)
      trackStack(asm, -1)
    }
    case LIxor -> {
      emitIxor(asm)
      trackStack(asm, -1)
    }
    case LIshl -> {
      emitIshl(asm)
      trackStack(asm, -1)
    }
    case LIshr -> {
      emitIshr(asm)
      trackStack(asm, -1)
    }
    case LIushr -> {
      emitIushr(asm)
      trackStack(asm, -1)
    }

    case LLneg -> emitLneg(asm)
    case LLrem -> {
      emitLrem(asm)
      trackStack(asm, -2)
    }
    case LLand -> {
      emitLand(asm)
      trackStack(asm, -2)
    }
    case LLor -> {
      emitLor(asm)
      trackStack(asm, -2)
    }
    case LLxor -> {
      emitLxor(asm)
      trackStack(asm, -2)
    }
    case LLshl -> {
      emitLshl(asm)
      trackStack(asm, -1)
    }
    case LLshr -> {
      emitLshr(asm)
      trackStack(asm, -1)
    }
    case LLushr -> {
      emitLushr(asm)
      trackStack(asm, -1)
    }
    case LLcmp -> {
      emitLcmp(asm)
      trackStack(asm, -3)
    }

    case LDrem -> {
      emitDrem(asm)
      trackStack(asm, -2)
    }
    case LDneg -> emitDneg(asm)
    case LFcmpl -> {
      emitFcmpl(asm)
      trackStack(asm, -1)
    }
    case LFcmpg -> {
      emitFcmpg(asm)
      trackStack(asm, -1)
    }
    case LDcmpl -> {
      emitDcmpl(asm)
      trackStack(asm, -3)
    }
    case LDcmpg -> {
      emitDcmpg(asm)
      trackStack(asm, -3)
    }

    case LL2f -> {
      emitL2f(asm)
      trackStack(asm, -1)
    }
    case LL2d -> emitL2d(asm)
    case LI2f -> emitI2f(asm)
    case LI2b -> emitI2b(asm)
    case LI2c -> emitI2c(asm)
    case LI2s -> emitI2s(asm)
    case LF2i -> emitF2i(asm)
    case LF2l -> {
      emitF2l(asm)
      trackStack(asm, 1)
    }
    case LF2d -> {
      emitF2d(asm)
      trackStack(asm, 1)
    }
    case LD2i -> {
      emitD2i(asm)
      trackStack(asm, -1)
    }
    case LD2l -> emitD2l(asm)
    case LD2f -> {
      emitD2f(asm)
      trackStack(asm, -1)
    }

    case LGoto(l) -> emitGoto(asm, l)
    case LIfeq(l) -> {
      emitIfeq(asm, l)
      trackStack(asm, -1)
    }
    case LIfnull(l) -> {
      emitIfnull(asm, l)
      trackStack(asm, -1)
    }
    case LIfnonnull(l) -> {
      emitIfnonnull(asm, l)
      trackStack(asm, -1)
    }
    case LIfne(l) -> {
      emitIfne(asm, l)
      trackStack(asm, -1)
    }
    case LIflt(l) -> {
      emitIflt(asm, l)
      trackStack(asm, -1)
    }
    case LIfge(l) -> {
      emitIfge(asm, l)
      trackStack(asm, -1)
    }
    case LIfgt(l) -> {
      emitIfgt(asm, l)
      trackStack(asm, -1)
    }
    case LIfle(l) -> {
      emitIfle(asm, l)
      trackStack(asm, -1)
    }
    case LIfIcmpeq(l) -> {
      emitIfIcmpeq(asm, l)
      trackStack(asm, -2)
    }
    case LIfIcmpne(l) -> {
      emitIfIcmpne(asm, l)
      trackStack(asm, -2)
    }
    case LIfIcmplt(l) -> {
      emitIfIcmplt(asm, l)
      trackStack(asm, -2)
    }
    case LIfIcmpge(l) -> {
      emitIfIcmpge(asm, l)
      trackStack(asm, -2)
    }
    case LIfIcmpgt(l) -> {
      emitIfIcmpgt(asm, l)
      trackStack(asm, -2)
    }
    case LIfIcmple(l) -> {
      emitIfIcmple(asm, l)
      trackStack(asm, -2)
    }
    case LIfAcmpeq(l) -> {
      emitIfAcmpeq(asm, l)
      trackStack(asm, -2)
    }
    case LIfAcmpne(l) -> {
      emitIfAcmpne(asm, l)
      trackStack(asm, -2)
    }

    case LGetfield(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitGetfield(asm, idx)
      trackStack(asm, fieldSlotSize(t) - 1)
    }
    case LPutfield(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitPutfield(asm, idx)
      trackStack(asm, -(fieldSlotSize(t) + 1))
    }
    case LGetstatic(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitGetstatic(asm, idx)
      trackStack(asm, fieldSlotSize(t))
    }
    case LPutstatic(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitPutstatic(asm, idx)
      trackStack(asm, -fieldSlotSize(t))
    }

    case LInvokevirtual(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokevirtual(asm, idx)
      // Precise net delta (like LInvokestatic, less the popped receiver): a flat 0 under-counts peakStack when the return is wider than the pops, e.g. a two-slot Double/Long unbox in a closure (#4798, docs/44 m-70).
      trackStack(asm, fieldSlotSize(ret) - slotSum(ps) - 1)
    }
    case LInvokespecial(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokespecial(asm, idx)
      // Receiver-based, precise net delta — see LInvokevirtual.
      trackStack(asm, fieldSlotSize(ret) - slotSum(ps) - 1)
    }
    case LInvokestatic(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokestatic(asm, idx)
      // Precise net delta: `ret` slots pushed minus the arg slots popped (no
      // receiver for a static call).  The flat `trackStack(asm, 0)` under-counts
      // the peak when a method pushes more than it pops — e.g. a 0-arg call
      // returning a value as the *first* instruction of a `<clinit>` (a
      // non-literal module-`val` initialiser, #2853), where peakStack would
      // otherwise stay 0 and the verifier rejects the method with a stack
      // overflow.  `trackStack` raises peakStack when the net delta is positive.
      trackStack(asm, fieldSlotSize(ret) - slotSum(ps))
    }
    case LInvokeinterface(owner, name, ps, ret, argCount) -> {
      val idx = poolIfaceMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokeinterface(asm, idx, argCount)
      // Receiver-based, precise net delta — see LInvokevirtual.
      trackStack(asm, fieldSlotSize(ret) - slotSum(ps) - 1)
    }

    case LNew(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitNew(asm, idx)
      trackStack(asm, 1)
    }
    case LCheckcast(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitCheckcast(asm, idx)
    }
    case LInstanceof(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitInstanceof(asm, idx)
    }
    case LAconstNull -> {
      emitAconstNull(asm)
      trackStack(asm, 1)
    }

    case LAnewarray(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitAnewarray(asm, idx)
    }
    case LNewarray(tc) -> emitNewarray(asm, tc)
    case LArraylength -> emitArraylength(asm)

    case LIaload -> {
      emitIaload(asm)
      trackStack(asm, -1)
    }
    case LLaload -> emitLaload(asm)
    case LFaload -> {
      emitFaload(asm)
      trackStack(asm, -1)
    }
    case LDaload -> emitDaload(asm)
    case LAaload -> {
      emitAaload(asm)
      trackStack(asm, -1)
    }
    case LBaload -> {
      emitBaload(asm)
      trackStack(asm, -1)
    }
    case LCaload -> {
      emitCaload(asm)
      trackStack(asm, -1)
    }
    case LSaload -> {
      emitSaload(asm)
      trackStack(asm, -1)
    }

    case LIastore -> {
      emitIastore(asm)
      trackStack(asm, -3)
    }
    case LLastore -> {
      emitLastore(asm)
      trackStack(asm, -4)
    }
    case LFastore -> {
      emitFastore(asm)
      trackStack(asm, -3)
    }
    case LDastore -> {
      emitDastore(asm)
      trackStack(asm, -4)
    }
    case LAastore -> {
      emitAastore(asm)
      trackStack(asm, -3)
    }
    case LBastore -> {
      emitBastore(asm)
      trackStack(asm, -3)
    }
    case LCastore -> {
      emitCastore(asm)
      trackStack(asm, -3)
    }
    case LSastore -> {
      emitSastore(asm)
      trackStack(asm, -3)
    }

    case LTableswitch(lo, hi, def, cases) -> {
      emitTableSwitch(asm, lo, hi, def, cases)
      trackStack(asm, -1)
    }
    case LLookupswitch(def, pairs) -> {
      emitLookupSwitch(asm, def, pairs)
      trackStack(asm, -1)
    }

    case LTryCatch(_, _, _, _) -> ()
    // meta-insn: collected by lowerFunc, no bytecode

    case LBoxInt -> {
      val ps: List[JvmType] = newList()
      ps.add(JInt)
      lowerInsn(
        LInvokestatic(
          owner = "java/lang/Integer",
          name = "valueOf",
          params = ps,
          ret = JRef(className = "java/lang/Integer")
        ),
        asm
      )
    }
    case LBoxLong -> {
      val ps: List[JvmType] = newList()
      ps.add(JLong)
      lowerInsn(
        LInvokestatic(owner = "java/lang/Long", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Long")),
        asm
      )
    }
    case LBoxFloat -> {
      val ps: List[JvmType] = newList()
      ps.add(JFloat)
      lowerInsn(
        LInvokestatic(owner = "java/lang/Float", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Float")),
        asm
      )
    }
    case LBoxDouble -> {
      val ps: List[JvmType] = newList()
      ps.add(JDouble)
      lowerInsn(
        LInvokestatic(owner = "java/lang/Double", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Double")),
        asm
      )
    }
    case LBoxBool -> {
      val ps: List[JvmType] = newList()
      ps.add(JBoolean)
      lowerInsn(
        LInvokestatic(
          owner = "java/lang/Boolean",
          name = "valueOf",
          params = ps,
          ret = JRef(className = "java/lang/Boolean")
        ),
        asm
      )
    }
    case LBoxByte -> {
      // A `JByte` operand is an int on the stack that may exceed the signed
      // byte range (e.g. an unsigned `Byte` 200 held as 200, not yet narrowed).
      // `Byte.valueOf(byte)` indexes a cache at `b + 128`, so an un-narrowed 200
      // gives index 328 → ArrayIndexOutOfBoundsException.  Narrow with `i2b`
      // first (200 → -56), matching the value a `byte` field/array store holds.
      emitI2b(asm)
      val ps: List[JvmType] = newList()
      ps.add(JByte)
      lowerInsn(
        LInvokestatic(owner = "java/lang/Byte", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Byte")),
        asm
      )
    }
    case LBoxChar -> {
      // Narrow to the char range before boxing so the operand matches the `(C)`
      // descriptor (`Character.valueOf` does not cache-crash, but keeping the
      // value in range mirrors the byte/short paths).
      emitI2c(asm)
      val ps: List[JvmType] = newList()
      ps.add(JChar)
      lowerInsn(
        LInvokestatic(
          owner = "java/lang/Character",
          name = "valueOf",
          params = ps,
          ret = JRef(className = "java/lang/Character")
        ),
        asm
      )
    }
    case LBoxShort -> {
      // Same cache-index hazard as `Byte.valueOf`: narrow with `i2s` first.
      emitI2s(asm)
      val ps: List[JvmType] = newList()
      ps.add(JShort)
      lowerInsn(
        LInvokestatic(owner = "java/lang/Short", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Short")),
        asm
      )
    }
    case LUnboxInt -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Integer", name = "intValue", params = ps, ret = JInt), asm)
    }
    case LUnboxLong -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Long", name = "longValue", params = ps, ret = JLong), asm)
    }
    case LUnboxFloat -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Float", name = "floatValue", params = ps, ret = JFloat), asm)
    }
    case LUnboxDouble -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Double", name = "doubleValue", params = ps, ret = JDouble), asm)
    }
    case LUnboxBool -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Boolean", name = "booleanValue", params = ps, ret = JBoolean), asm)
    }
    case LUnboxByte -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Byte", name = "byteValue", params = ps, ret = JByte), asm)
    }
    case LUnboxChar -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Character", name = "charValue", params = ps, ret = JChar), asm)
    }
    case LUnboxShort -> {
      val ps: List[JvmType] = newList()
      lowerInsn(LInvokevirtual(owner = "java/lang/Short", name = "shortValue", params = ps, ret = JShort), asm)
    }
    case LYield -> panic("LYield used outside an async-generator body")
  }
  // LYield is a meta-insn for async generators; it must not appear in
  // general-purpose lowering.  Callers should use lowerAsyncGenerator
  // which handles LYield inside RunBody bodies.
}

// ── LField / LFunc / LRecord ─────────────────────────────────────────────────
pub record LField {
  flags: Int
  name: String
  fieldType: JvmType
}

pub record LFunc {
  flags: Int
  name: String
  params: List[JvmType]
  ret: JvmType
  insns: List[LInsn]
  maxStack: Int
  maxLocals: Int
}

pub record LRecord {
  className: String
  fields: List[LField]
  methods: List[LFunc]
  implementsIfaces: List[String]
  // ── Type helpers (no OR patterns) ────────────────────────────────────────────
  // Emit the appropriate load instruction for parameter slot `slot` of type `t`.
}

func emitFieldLoad(t: in JvmType, slot: in Int, asm: in MethodAssembler): Unit {
  match t {
    case JLong -> lowerInsn(LLload(slot = slot), asm)
    case JDouble -> lowerInsn(LDload(slot = slot), asm)
    case JBoolean -> lowerInsn(LIload(slot = slot), asm)
    case JByte -> lowerInsn(LIload(slot = slot), asm)
    case JChar -> lowerInsn(LIload(slot = slot), asm)
    case JShort -> lowerInsn(LIload(slot = slot), asm)
    case JInt -> lowerInsn(LIload(slot = slot), asm)
    case JFloat -> lowerInsn(LFload(slot = slot), asm)
    case JVoid -> ()
    case JRef(_) -> lowerInsn(LAload(slot = slot), asm)
    case JArray(_) -> lowerInsn(LAload(slot = slot), asm)
  }
}

// ── B5: Stack-map frame computation ──────────────────────────────────────────
//
// For class files with major version ≥ 50 (we emit Java 21 = 65), the JVM
// verifier requires a StackMapTable attribute inside every Code attribute
// that contains branch targets.  We compute it in a single forward pass,
// exploiting the fact that all code generated by Jvm.Lowering has:
//   • An empty operand stack at every branch target.
//   • Locals that equal the method's initial parameter frame (no inter-branch
//     local variable stores occur in the generated code).
// Both invariants hold for B3/B4 lowerings and the B5 self-test.
// VerifierType is defined in Jvm.Bytecode (imported above) and re-used here.
// VTop, VInteger, VFloat, VLong, VDouble, VNull, VObject come from that import.
// Convert a JvmType to its VerifierType equivalent.
pub func jvmToVerifier(t: in JvmType): VerifierType {
  match t {
    case JBoolean -> VInteger
    case JByte -> VInteger
    case JChar -> VInteger
    case JShort -> VInteger
    case JInt -> VInteger
    case JFloat -> VFloat
    case JLong -> VLong
    case JDouble -> VDouble
    case JVoid -> VTop
    case JRef(cls) -> VObject(className = cls)
    case JArray(el) -> VObject(className = "[" + typeDescriptor(el))
  }
}

// Add `l` to the Map-as-set `targets` if not already present.
func addTarget(targets: in Map[String, Bool], l: in String): Unit {
  match mapGet(targets, l) {
    case None -> targets.add(l, true)
    case Some(_) -> ()
  }
}

// Helper: add every label in a `List[String]` to `targets`.  Indirected
// through a typed parameter so the codegen has the concrete `List[String]`
// type for `.count` / indexing — non-generic-union erasure (D035) drops
// the destructured-binding type to `obj` inside the case arm, which the
// member-dispatch path doesn't reconstruct on its own.
func addLabelTargets(targets: in Map[String, Bool], labels: in List[String]): Unit {
  var i = 0
  while i < labels.count {
    addTarget(targets, labels[i])
    i = i + 1
  }
}

// Helper: add every pair's label in a `List[SwitchPair]` to `targets`.
// Same indirection rationale as `addLabelTargets`.
func addPairLabelTargets(targets: in Map[String, Bool], pairs: in List[SwitchPair]): Unit {
  var i = 0
  while i < pairs.count {
    addTarget(targets, pairs[i].label)
    i = i + 1
  }
}

// Return a set (Map[String, Bool]) of label names that are branch targets
// in the LInsn list.
//
// D035 erasure: List[T] fields inside non-generic union cases (e.g.
// LTableswitch.caseLabels and LLookupswitch.pairs) are stored as Object
// at the CLR level, so we cannot call .count on them inside a match arm.
// We iterate via `addLabelTargets` / `addPairLabelTargets` helpers above —
// passing the destructured value through a typed `in List[T]` parameter
// recovers the concrete type for `.count` / indexing on the helper side.
func collectBranchTargets(insns: in List[LInsn]): Map[String, Bool] {
  val targets: Map[String, Bool] = newMap()
  var i = 0
  while i < insns.count {
    match insns[i] {
      case LLabel(l) -> addTarget(targets, l)
      case LGoto(l) -> addTarget(targets, l)
      case LIfeq(l) -> addTarget(targets, l)
      case LIfnull(l) -> addTarget(targets, l)
      case LIfnonnull(l) -> addTarget(targets, l)
      case LIfne(l) -> addTarget(targets, l)
      case LIflt(l) -> addTarget(targets, l)
      case LIfge(l) -> addTarget(targets, l)
      case LIfgt(l) -> addTarget(targets, l)
      case LIfle(l) -> addTarget(targets, l)
      case LIfIcmpeq(l) -> addTarget(targets, l)
      case LIfIcmpne(l) -> addTarget(targets, l)
      case LIfIcmplt(l) -> addTarget(targets, l)
      case LIfIcmpge(l) -> addTarget(targets, l)
      case LIfIcmpgt(l) -> addTarget(targets, l)
      case LIfIcmple(l) -> addTarget(targets, l)
      case LIfAcmpeq(l) -> addTarget(targets, l)
      case LIfAcmpne(l) -> addTarget(targets, l)
      case LTableswitch(_, _, def, cases) -> {
        addTarget(targets, def)
        addLabelTargets(targets, cases)
      }
      case LLookupswitch(def, pairs) -> {
        addTarget(targets, def)
        addPairLabelTargets(targets, pairs)
      }
      case _ -> ()
    }
    i = i + 1
  }
  targets
}

// ── Lowering ──────────────────────────────────────────────────────────────────
// Infer the minimum maxLocals needed by scanning the instruction list for the
// highest slot index used by any load/store instruction.
func inferMaxLocals(f: in LFunc): Int {
  var maxSlot = 0
  var i = 0
  while i < f.insns.count {
    match f.insns[i] {
      case LIload(s) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LLload(s) -> {
        if s + 2 > maxSlot {
          maxSlot = s + 2
        }
      }
      case LFload(s) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LDload(s) -> {
        if s + 2 > maxSlot {
          maxSlot = s + 2
        }
      }
      case LAload(s) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LIstore(s) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LLstore(s) -> {
        if s + 2 > maxSlot {
          maxSlot = s + 2
        }
      }
      case LFstore(s) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LDstore(s) -> {
        if s + 2 > maxSlot {
          maxSlot = s + 2
        }
      }
      case LAstore(s) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LAstoreAs(s, _) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case LIinc(s, _) -> {
        if s + 1 > maxSlot {
          maxSlot = s + 1
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  // Account for parameter slots (always allocated at 0..N-1).
  val paramSlots = slotSum(f.params)
  if paramSlots > maxSlot {
    maxSlot = paramSlots
  }
  // For virtual methods slot 0 is `this`; ACC_STATIC = 0x0008.
  val isStatic = (f.flags / 8) % 2 == 1
  if not isStatic and maxSlot < 1 {
    maxSlot = 1
  }
  maxSlot
}

// Internal implementation: thisTypeName overrides the receiver type in the StackMapTable.
// Use "java/lang/Object" for the default (static or unknown class) and the actual class
// name for instance methods where the verifier checks field access (B118+).
func lowerFuncImpl(f: in LFunc, thisTypeName: in String, pool: in Pool): MethodInfo {
  // Build initial local variable frame from the method's parameter types.
  // ACC_STATIC = 0x0008 = 8; test using (flags / 8) % 2.
  val initialLocals: List[VerifierType] = newList()
  val isStatic = (f.flags / 8) % 2 == 1
  if not isStatic {
    initialLocals.add(VObject(className = thisTypeName))
  }
  var pi = 0
  while pi < f.params.count {
    initialLocals.add(jvmToVerifier(f.params[pi]))
    pi = pi + 1
  }

  // Pre-pass: collect types for any local slots assigned via store instructions.
  // Also collect LTryCatch meta-insns for the exception table and StackMapTable.
  val storeTypes: Map[Int, VerifierType] = newMap()
  val tcStartLabels: List[String] = newList()
  val tcEndLabels: List[String] = newList()
  val tcHandlerLabels: List[String] = newList()
  val tcCatchClasses: List[String] = newList()
  val handlerTargets: Map[String, String] = newMap()
  // handlerLabel -> catchClass
  var pi3 = 0
  while pi3 < f.insns.count {
    match f.insns[pi3] {
      case LIstore(s) -> {
        match mapGet(storeTypes, s) {
          case None -> storeTypes.add(s, VInteger)
          case Some(_) -> ()
        }
      }
      case LLstore(s) -> {
        match mapGet(storeTypes, s) {
          case None -> storeTypes.add(s, VLong)
          case Some(_) -> ()
        }
      }
      case LDstore(s) -> {
        match mapGet(storeTypes, s) {
          case None -> storeTypes.add(s, VDouble)
          case Some(_) -> ()
        }
      }
      case LFstore(s) -> {
        match mapGet(storeTypes, s) {
          case None -> storeTypes.add(s, VFloat)
          case Some(_) -> ()
        }
      }
      case LAstore(s) -> {
        match mapGet(storeTypes, s) {
          case None -> storeTypes.add(s, VObject(className = "java/lang/Object"))
          case Some(_) -> ()
        }
      }
      case LAstoreAs(s, cls) -> {
        match mapGet(storeTypes, s) {
          case None -> storeTypes.add(s, VObject(className = cls))
          case Some(_) -> ()
        }
      }
      case LTryCatch(sl, el, hl, cc) -> {
        tcStartLabels.add(sl)
        tcEndLabels.add(el)
        tcHandlerLabels.add(hl)
        tcCatchClasses.add(cc)
        match mapGet(handlerTargets, hl) {
          case None -> handlerTargets.add(hl, cc)
          case Some(_) -> ()
        }
      }
      case _ -> ()
    }
    pi3 = pi3 + 1
  }

  // Compute how many actual JVM slots the parameter frame covers.
  // Long and Double each occupy 2 slots; all others occupy 1.
  // For non-static methods, slot 0 ('this') is already counted separately;
  // start the loop at index 1 to skip it.
  var paramSlotCount = 0
  if not isStatic {
    paramSlotCount = 1
  }
  var ili = if isStatic then 0 else 1
  while ili < initialLocals.count {
    match initialLocals[ili] {
      case VLong -> {
        paramSlotCount = paramSlotCount + 2
      }
      case VDouble -> {
        paramSlotCount = paramSlotCount + 2
      }
      case _ -> {
        paramSlotCount = paramSlotCount + 1
      }
    }
    ili = ili + 1
  }

  // Compute actualMaxLocals before assembly so we know the pre-init range.
  val actualMaxLocals = if f.maxLocals > 0 then f.maxLocals else inferMaxLocals(f)

  // Assemble: emit pre-initializations for all non-parameter local slots first,
  // then emit the function body.  Pre-initializing every local slot guarantees
  // that every StackMapTable branch-target frame sees all slots as initialized,
  // preventing VerifyError for locals declared inside loops or late in the body.
  val asm = newAssembler(pool)
  var preSlot = paramSlotCount
  while preSlot < actualMaxLocals {
    match mapGet(storeTypes, preSlot) {
      case Some(VInteger) -> {
        lowerInsn(LIconst(v = 0), asm)
        lowerInsn(LIstore(slot = preSlot), asm)
        preSlot = preSlot + 1
      }
      case Some(VLong) -> {
        lowerInsn(LLconst(v = 0i64), asm)
        lowerInsn(LLstore(slot = preSlot), asm)
        preSlot = preSlot + 2
      }
      case Some(VFloat) -> {
        lowerInsn(LFconst(v = 0.0), asm)
        lowerInsn(LFstore(slot = preSlot), asm)
        preSlot = preSlot + 1
      }
      case Some(VDouble) -> {
        lowerInsn(LDconst(v = 0.0), asm)
        lowerInsn(LDstore(slot = preSlot), asm)
        preSlot = preSlot + 2
      }
      case Some(VObject(_)) -> {
        lowerInsn(LAconstNull, asm)
        lowerInsn(LAstore(slot = preSlot), asm)
        preSlot = preSlot + 1
      }
      case _ -> {
        preSlot = preSlot + 1
      }
    }
  }
  for insn in f.insns.toArray() {
    lowerInsn(insn, asm)
  }

  // Use caller-supplied maxStack/maxLocals when > 0; otherwise infer from the
  // assembled instruction sequence (B103 feature).
  val actualMaxStack = if f.maxStack > 0 then f.maxStack else asm.peakStack

  // -- B5: stack-map computation -----------------------------------------
  // Assemble code bytes and collect label offsets.
  val ar = assembleRaw(asm)

  // Build the full frame locals list: params first, then any extra stored slots.
  val frameLocals: List[VerifierType] = newList()
  var fli = 0
  while fli < initialLocals.count {
    frameLocals.add(initialLocals[fli])
    fli = fli + 1
  }
  var slotIdx = paramSlotCount
  while slotIdx < actualMaxLocals {
    match mapGet(storeTypes, slotIdx) {
      case Some(vt) -> {
        frameLocals.add(vt)
        match vt {
          case VLong -> {
            slotIdx = slotIdx + 2
          }
          case VDouble -> {
            slotIdx = slotIdx + 2
          }
          case _ -> {
            slotIdx = slotIdx + 1
          }
        }
      }
      case None -> {
        slotIdx = slotIdx + 1
      }
    }
  }

  // Walk the LInsn list in order; for each LLabel that is a branch target,
  // emit a full_frame (255) StackMapTable entry.
  val branchTargets = collectBranchTargets(f.insns)
  // Exception handler labels are also branch targets for the StackMapTable.
  var hti = 0
  while hti < tcHandlerLabels.count {
    val hl = tcHandlerLabels[hti]
    match mapGet(branchTargets, hl) {
      case None -> branchTargets.add(hl, true)
      case Some(_) -> ()
    }
    hti = hti + 1
  }
  val smBuf = writerNew()
  // raw frame bytes (no leading count)
  var smCount = 0

  // Collect one frame per *distinct* bytecode offset.  Multiple branch-target
  // labels can resolve to the same offset — most importantly a try-region end
  // label (empty stack) coinciding with a catch handler label (which needs the
  // caught exception on the stack).  Emitting both produced two frames at the
  // same offset, so the second frame's `offset_delta = off - prevOffset - 1`
  // underflowed to -1 and was written as 65535, shifting every later frame by
  // 64KB (VerifyError / "Current Frame bci @65595").  Dedupe by offset, letting
  // a handler frame win so the offset carries `[Throwable]` on its stack.
  val frameOffs: List[Int] = newList()
  // distinct offsets, ascending
  val frameEx: List[String] = newList()
  // "" = empty stack; else exception class
  val seenOff: Map[Int, Int] = newMap()
  // offset -> index into frameOffs

  var si = 0
  while si < f.insns.count {
    match f.insns[si] {
      case LLabel(l) -> {
        if branchTargets.containsKey(l) {
          match mapGet(ar.labelOffsets, l) {
            case Some(off) -> {
              val ex = match mapGet(handlerTargets, l) {
                case Some(cc) -> if cc == "" { "java/lang/Throwable" } else { cc }
                case None -> ""
              }
              match mapGet(seenOff, off) {
                case None -> {
                  seenOff.add(off, frameOffs.count)
                  frameOffs.add(off)
                  frameEx.add(ex)
                }
                case Some(idx) -> {
                  // Duplicate offset: a handler (non-empty stack) frame wins.
                  if ex != "" {
                    frameEx[idx] = ex
                  }
                }
              }
            }
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
    si = si + 1
  }

  // Add basic-block starts (instructions following an unconditional transfer)
  // that are not already branch-target frame points.  The verifier requires a
  // frame at every block start, including dead code after a `panic`'s athrow.
  var bsi = 0
  while bsi < ar.blockStarts.count {
    val bso = ar.blockStarts[bsi]
    if not seenOff.containsKey(bso) {
      seenOff.add(bso, frameOffs.count)
      frameOffs.add(bso)
      frameEx.add("")
    }
    bsi = bsi + 1
  }

  // Frame offsets must be emitted in strictly ascending order (offset_delta is
  // relative).  Label and block-start offsets interleave, so sort both parallel
  // lists by offset (insertion sort — frame counts are small).
  var a = 1
  while a < frameOffs.count {
    val ko = frameOffs[a]
    val ke = frameEx[a]
    var b = a - 1
    while b >= 0 and frameOffs[b] > ko {
      frameOffs[b + 1] = frameOffs[b]
      frameEx[b + 1] = frameEx[b]
      b = b - 1
    }
    frameOffs[b + 1] = ko
    frameEx[b + 1] = ke
    a = a + 1
  }

  var prevOffset = -1
  // initial implicit frame is at offset -1
  var fi2 = 0
  while fi2 < frameOffs.count {
    val off = frameOffs[fi2]
    val delta = off - prevOffset - 1
    writerByte(smBuf, 255)
    // full_frame tag
    writerU2(smBuf, delta)
    // offset_delta
    writerU2(smBuf, frameLocals.count)
    var vi = 0
    while vi < frameLocals.count {
      emitVerifierTypeBc(frameLocals[vi], pool, smBuf)
      vi = vi + 1
    }
    if frameEx[fi2] != "" {
      writerU2(smBuf, 1)
      // 1 stack item: the caught exception
      emitVerifierTypeBc(VObject(className = frameEx[fi2]), pool, smBuf)
    } else {
      writerU2(smBuf, 0)
      // empty stack
    }
    smCount = smCount + 1
    prevOffset = off
    fi2 = fi2 + 1
  }

  // Build the Code attribute body.  If there are StackMapTable entries,
  // embed them as a nested attribute (JVMS §4.7.3, §4.7.4).
  val codeW = writerNew()
  writerU2(codeW, actualMaxStack)
  writerU2(codeW, actualMaxLocals)
  writerU4(codeW, ar.codeBytes.count)
  writerByteList(codeW, ar.codeBytes)
  writerU2(codeW, tcStartLabels.count)
  // exception_table_length
  var tci = 0
  while tci < tcStartLabels.count {
    val spOff = match mapGet(ar.labelOffsets, tcStartLabels[tci]) { case Some(v) -> v; case None -> 0 }
    val epOff = match mapGet(ar.labelOffsets, tcEndLabels[tci]) { case Some(v) -> v; case None -> 0 }
    val hpOff = match mapGet(ar.labelOffsets, tcHandlerLabels[tci]) { case Some(v) -> v; case None -> 0 }
    val cc = tcCatchClasses[tci]
    val ct = if cc == "" { 0 } else { poolClass(pool, cc) }
    writerU2(codeW, spOff)
    writerU2(codeW, epOff)
    writerU2(codeW, hpOff)
    writerU2(codeW, ct)
    tci = tci + 1
  }
  if smCount > 0 {
    writerU2(codeW, 1)
    // attributes_count = 1
    writerU2(codeW, poolUtf8(pool, "StackMapTable"))
    val smBytes = writerToList(smBuf)
    writerU4(codeW, 2 + smBytes.count)
    // length = u2(count) + frames
    writerU2(codeW, smCount)
    writerByteList(codeW, smBytes)
  } else {
    writerU2(codeW, 0)
    // attributes_count = 0
  }

  val codeAttr = attrFromWriter("Code", codeW)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  makeMethodInfo(f.flags, f.name, buildDescriptor(f.params, f.ret), attrs)
}

/// Lower a static or top-level LFunc to a MethodInfo.
pub func lowerFunc(f: in LFunc, pool: in Pool): MethodInfo {
  lowerFuncImpl(f, "java/lang/Object", pool)
}

/// Lower an instance LFunc where the receiver type matters in StackMapTable frames.
pub func lowerFuncForClass(f: in LFunc, declaringClass: in String, pool: in Pool): MethodInfo {
  lowerFuncImpl(f, declaringClass, pool)
}

pub func lowerRecord(r: in LRecord, pool: in Pool): ClassFile {
  val methods: List[MethodInfo] = newList()

  // ── Synthesise <init>(field…)V ─────────────────────────────────────────────
  val ctorAsm = newAssembler(pool)

  // aload_0; invokespecial java/lang/Object.<init>:()V
  lowerInsn(LAload(slot = 0), ctorAsm)
  val objInitPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = objInitPs, ret = JVoid), ctorAsm)

  // For each field: aload_0; load param at slot; putfield
  var slot = 1
  for fld in r.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    emitFieldLoad(fld.fieldType, slot, ctorAsm)
    lowerInsn(LPutfield(owner = r.className, name = fld.name, t = fld.fieldType), ctorAsm)
    slot = slot + fieldSlotSize(fld.fieldType)
  }
  lowerInsn(LReturn, ctorAsm)

  val ctorCode = assembleCode(ctorAsm, slot + 1, slot)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)

  val ctorParams: List[JvmType] = newList()
  for fld in r.fields.toArray() {
    ctorParams.add(fld.fieldType)
  }
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParams, JVoid), ctorAttrs)
  methods.add(ctorMethod)

  // ── Emit explicit methods ──────────────────────────────────────────────────
  // A non-static method (record instance method / protected-type entry) has
  // `this` in slot 0; the StackMapTable must type slot 0 as the *record class*,
  // not `java/lang/Object`, or a `getfield <recClass>.field` on the receiver
  // fails verification ("Type 'java/lang/Object' is not assignable").  Route
  // instance methods through `lowerFuncForClass` so slot 0 carries the precise
  // receiver type; static methods keep the `java/lang/Object` frame (#2865).
  for fn in r.methods.toArray() {
    val isStatic = (fn.flags / 8) % 2 == 1
    if isStatic {
      methods.add(lowerFunc(fn, pool))
    } else {
      methods.add(lowerFuncForClass(fn, r.className, pool))
    }
  }

  // ── Build FieldInfo list ───────────────────────────────────────────────────
  val cfFields: List[FieldInfo] = newList()
  for fld in r.fields.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PUBLIC, fld.name, typeDescriptor(fld.fieldType), fa))
  }

  if r.implementsIfaces.count > 0 {
    makeClassFullWithInterfaces(r.className, r.implementsIfaces, cfFields, methods)
  } else {
    makeClassFull(r.className, cfFields, methods)
  }
}

// ── B6: Protected types and wire blocks ──────────────────────────────────────
//
// `protected type` → final class with private ReentrantLock, private data
// fields, a no-arg constructor that zero-initialises them, and entry methods
// wrapped with lock-acquire / lock-release.
//
// `wire` → final class with a private constructor, private static fields (one
// per binding), a public static bootstrap()V that initialises those fields,
// and public static accessors for each exposed binding.
//
// Entry method convention (for `lowerEntry`):
//   The caller's LFunc.insns push the return value onto the stack and then
//   stop — no explicit return instruction.  For void entries, the stack is
//   left empty.  `lowerEntry` prepends lock acquisition, appends lock
//   release, saves/restores the return value, and emits the return opcode.
pub record LProtected {
  className: String
  fields: List[LField]
  // non-lock data fields (will be emitted as private)
  entries: List[LFunc]
  // each insns list pushes the result; no return insn
}

pub record LWireBinding {
  name: String
  valType: JvmType
  insns: List[LInsn]
  // push the constructed value; no return insn
}

// A @provided parameter to the wire's bootstrap() method.
pub record LWireParam {
  name: String
  valType: JvmType
}

pub record LWire {
  className: String
  providedParams: List[LWireParam]
  // @provided parameters, in declaration order — become bootstrap() args
  bindings: List[LWireBinding]
  exposes: List[String]
  // binding names to expose as public static accessors
  // Store a value of type `t` to local slot `slot`.
}

func storeInsn(t: in JvmType, slot: in Int): LInsn {
  match t {
    case JLong -> LLstore(slot = slot)
    case JDouble -> LDstore(slot = slot)
    case JBoolean -> LIstore(slot = slot)
    case JByte -> LIstore(slot = slot)
    case JChar -> LIstore(slot = slot)
    case JShort -> LIstore(slot = slot)
    case JInt -> LIstore(slot = slot)
    case JFloat -> LFstore(slot = slot)
    case JVoid -> LNop
    case JRef(_) -> LAstore(slot = slot)
    case JArray(_) -> LAstore(slot = slot)
  }
}

// Load a value of type `t` from local slot `slot`.
func loadInsn(t: in JvmType, slot: in Int): LInsn {
  match t {
    case JLong -> LLload(slot = slot)
    case JDouble -> LDload(slot = slot)
    case JBoolean -> LIload(slot = slot)
    case JByte -> LIload(slot = slot)
    case JChar -> LIload(slot = slot)
    case JShort -> LIload(slot = slot)
    case JInt -> LIload(slot = slot)
    case JFloat -> LFload(slot = slot)
    case JVoid -> LNop
    case JRef(_) -> LAload(slot = slot)
    case JArray(_) -> LAload(slot = slot)
  }
}

// Return instruction appropriate for return type `t`.
func returnInsn(t: in JvmType): LInsn {
  match t {
    case JLong -> LLreturn
    case JDouble -> LDreturn
    case JBoolean -> LIreturn
    case JByte -> LIreturn
    case JChar -> LIreturn
    case JShort -> LIreturn
    case JInt -> LIreturn
    case JFloat -> LFreturn
    case JVoid -> LReturn
    case JRef(_) -> LAreturn
    case JArray(_) -> LAreturn
  }
}

// True if `name` appears in the `exposes` list.
func isExposed(name: in String, exposes: in List[String]): Bool {
  var found = false
  var ei = 0
  while ei < exposes.count {
    if exposes[ei] == name {
      found = true
    }
    ei = ei + 1
  }
  found
}

// Lower one entry method by synthesising a wrapper LFunc whose instruction
// list is: [lock acquire] ++ ef.insns ++ [save result] ++ [lock release]
// ++ [load result] ++ [return].
// (`entry` is a reserved keyword; the parameter is named `ef`.)
func lowerEntry(ef: in LFunc, className: in String, pool: in Pool): MethodInfo {
  val lockType = JRef(className = "java/util/concurrent/locks/ReentrantLock")
  val lockPs: List[JvmType] = newList()

  val wInsns: List[LInsn] = newList()

  // Acquire: aload_0; getfield _lock; invokevirtual lock()
  wInsns.add(LAload(slot = 0))
  wInsns.add(LGetfield(owner = className, name = "_lock", t = lockType))
  wInsns.add(
    LInvokevirtual(owner = "java/util/concurrent/locks/ReentrantLock", name = "lock", params = lockPs, ret = JVoid)
  )

  // Body (pushes return value or leaves stack empty for void)
  var bi = 0
  while bi < ef.insns.count {
    wInsns.add(ef.insns[bi])
    bi = bi + 1
  }

  // For non-void: save result to a temp local before releasing the lock
  val resultSlot = ef.maxLocals
  if fieldSlotSize(ef.ret) > 0 {
    wInsns.add(storeInsn(ef.ret, resultSlot))
  }

  // Release: aload_0; getfield _lock; invokevirtual unlock()
  wInsns.add(LAload(slot = 0))
  wInsns.add(LGetfield(owner = className, name = "_lock", t = lockType))
  wInsns.add(
    LInvokevirtual(owner = "java/util/concurrent/locks/ReentrantLock", name = "unlock", params = lockPs, ret = JVoid)
  )

  // Reload result and return
  if fieldSlotSize(ef.ret) > 0 {
    wInsns.add(loadInsn(ef.ret, resultSlot))
  }
  wInsns.add(returnInsn(ef.ret))

  val wFunc = LFunc(
    flags = ef.flags,
    name = ef.name,
    params = ef.params,
    ret = ef.ret,
    insns = wInsns,
    maxStack = ef.maxStack + 2,
    // +2 headroom for lock acquire/release
    maxLocals = ef.maxLocals + fieldSlotSize(ef.ret)
  )
  lowerFuncForClass(wFunc, className, pool)
}

pub func lowerProtected(p: in LProtected, pool: in Pool): ClassFile {
  val lockType = JRef(className = "java/util/concurrent/locks/ReentrantLock")
  val methods: List[MethodInfo] = newList()
  val cfFields: List[FieldInfo] = newList()

  // _lock (private)
  val lockFa: List[Attribute] = newList()
  cfFields.add(makeFieldInfo(ACC_PRIVATE, "_lock", typeDescriptor(lockType), lockFa))

  // Data fields (private)
  for fld in p.fields.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PRIVATE, fld.name, typeDescriptor(fld.fieldType), fa))
  }

  // Constructor: <init>()V — super(), new lock, zero-init data fields
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val objPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid), ctorAsm)

  // aload_0; new RL; dup; invokespecial RL.<init>; putfield _lock
  lowerInsn(LAload(slot = 0), ctorAsm)
  lowerInsn(LNew(className = "java/util/concurrent/locks/ReentrantLock"), ctorAsm)
  lowerInsn(LDup, ctorAsm)
  val rlPs: List[JvmType] = newList()
  lowerInsn(
    LInvokespecial(owner = "java/util/concurrent/locks/ReentrantLock", name = "<init>", params = rlPs, ret = JVoid),
    ctorAsm
  )
  lowerInsn(LPutfield(owner = p.className, name = "_lock", t = lockType), ctorAsm)

  // Zero-initialise each data field
  for fld in p.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    match fld.fieldType {
      case JInt -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JBoolean -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JByte -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JChar -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JShort -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JFloat -> lowerInsn(LFconst(v = 0.0), ctorAsm)
      case JLong -> {
        lowerInsn(LIconst(v = 0), ctorAsm)
        lowerInsn(LI2l, ctorAsm)
      }
      case JDouble -> {
        lowerInsn(LIconst(v = 0), ctorAsm)
        lowerInsn(LI2d, ctorAsm)
      }
      case JVoid -> ()
      case JRef(_) -> lowerInsn(LAconstNull, ctorAsm)
      case JArray(_) -> lowerInsn(LAconstNull, ctorAsm)
    }
    match fld.fieldType {
      case JVoid -> ()
      case _ -> lowerInsn(LPutfield(owner = p.className, name = fld.name, t = fld.fieldType), ctorAsm)
    }
  }

  lowerInsn(LReturn, ctorAsm)

  // maxStack=3 (aload_0 + new RL + dup before invokespecial), maxLocals=1 (this)
  val ctorCode = assembleCode(ctorAsm, 3, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamsEmpty: List[JvmType] = newList()
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParamsEmpty, JVoid), ctorAttrs)
  methods.add(ctorMethod)

  // Entry methods (wrapped with lock acquire / release)
  for ef in p.entries.toArray() {
    methods.add(lowerEntry(ef, p.className, pool))
  }

  makeFinalClass(p.className, cfFields, methods)
}

pub func lowerWire(w: in LWire, pool: in Pool): ClassFile {
  val methods: List[MethodInfo] = newList()
  val cfFields: List[FieldInfo] = newList()

  // Static fields (private static) for @provided params and each binding.
  // Provided-param fields must exist so bootstrap() can putstatic them.
  var pfIdx = 0
  while pfIdx < w.providedParams.count {
    val pf = w.providedParams[pfIdx]
    val pfAttrs: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PRIVATE + ACC_STATIC, pf.name, typeDescriptor(pf.valType), pfAttrs))
    pfIdx = pfIdx + 1
  }
  for b in w.bindings.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PRIVATE + ACC_STATIC, b.name, typeDescriptor(b.valType), fa))
  }

  // Private constructor (prevents external instantiation)
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val objPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid), ctorAsm)
  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 1, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamsEmpty: List[JvmType] = newList()
  val ctorMethod = makeMethodInfo(ACC_PRIVATE, "<init>", buildDescriptor(ctorParamsEmpty, JVoid), ctorAttrs)
  methods.add(ctorMethod)

  // bootstrap(provided...)V — first store any @provided params to static fields,
  // then run each remaining binding's insns and store to its static field.
  val bsAsm = newAssembler(pool)

  // Store each @provided param (slot 0..n-1 in a static method) to its static field.
  var bsSlot = 0
  var bspi = 0
  while bspi < w.providedParams.count {
    val p = w.providedParams[bspi]
    lowerInsn(loadInsn(p.valType, bsSlot), bsAsm)
    lowerInsn(LPutstatic(owner = w.className, name = p.name, t = p.valType), bsAsm)
    bsSlot = bsSlot + fieldSlotSize(p.valType)
    bspi = bspi + 1
  }

  // Run remaining bindings (WMSingleton / WMLocal / WMBind etc.).
  for b in w.bindings.toArray() {
    for insn in b.insns.toArray() {
      lowerInsn(insn, bsAsm)
    }
    lowerInsn(LPutstatic(owner = w.className, name = b.name, t = b.valType), bsAsm)
  }
  lowerInsn(LReturn, bsAsm)

  val bsMaxStack = 3
  // bsSlot is the total local-slot count after the loop (category-2 types
  // like Long/Double occupy 2 slots each per JVM spec §4.7.3).
  val bsMaxLocals = bsSlot
  val bsCode = assembleCode(bsAsm, bsMaxStack, bsMaxLocals)
  val bsAttrs: List[Attribute] = newList()
  bsAttrs.add(bsCode)
  val bsParamTypes: List[JvmType] = newList()
  var bspt = 0
  while bspt < w.providedParams.count {
    bsParamTypes.add(w.providedParams[bspt].valType)
    bspt = bspt + 1
  }
  val bsMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "bootstrap", buildDescriptor(bsParamTypes, JVoid), bsAttrs)
  methods.add(bsMethod)

  // Public static accessor for each exposed binding: getstatic + return
  for b in w.bindings.toArray() {
    if isExposed(b.name, w.exposes) {
      val accAsm = newAssembler(pool)
      lowerInsn(LGetstatic(owner = w.className, name = b.name, t = b.valType), accAsm)
      lowerInsn(returnInsn(b.valType), accAsm)
      val accCode = assembleCode(accAsm, 1, 0)
      val accAttrs: List[Attribute] = newList()
      accAttrs.add(accCode)
      val accParamsEmpty: List[JvmType] = newList()
      val accMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, b.name, buildDescriptor(accParamsEmpty, b.valType), accAttrs)
      methods.add(accMethod)
    }
  }

  makeFinalClass(w.className, cfFields, methods)
}

// ── B4: Union-type lowering ───────────────────────────────────────────────────
//
// A Lyric union `union Option { case Some(value: Int); case None }` maps to:
//   - An abstract base class `Option`  (ACC_PUBLIC | ACC_ABSTRACT)
//   - A concrete case class  `Option$Some` extends `Option` with field `value`
//   - A concrete case class  `Option$None` extends `Option`
//
// Pattern matching is performed at the call site using `instanceof` checks
// and `checkcast` to the specific case class.
pub record LUnionCase {
  caseName: String
  // simple case name (e.g. "Some")
  fields: List[LField]
  // case payload fields
}

pub record LUnion {
  baseName: String
  // JVM internal binary name (e.g. "Option")
  cases: List[LUnionCase]
  methods: List[LFunc]
  // methods on the base class
}

/// Returns the JVM internal name for a case class:
/// `<baseName>$<caseName>` (dollar-separated, JVM convention).
pub func caseClassName(baseName: in String, caseName: in String): String {
  baseName + "$" + caseName
}

/// Lower one case class (concrete subclass of the union base).
func lowerCase(baseName: in String, c: in LUnionCase, pool: in Pool): ClassFile {
  val fullName = caseClassName(baseName, c.caseName)

  // Fields
  val cfFields: List[FieldInfo] = newList()
  for fld in c.fields.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PUBLIC, fld.name, typeDescriptor(fld.fieldType), fa))
  }

  // Synthesise <init>(field…)V — same logic as lowerRecord but super is baseName
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val superPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = baseName, name = "<init>", params = superPs, ret = JVoid), ctorAsm)

  var slot = 1
  for fld in c.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    emitFieldLoad(fld.fieldType, slot, ctorAsm)
    lowerInsn(LPutfield(owner = fullName, name = fld.name, t = fld.fieldType), ctorAsm)
    slot = slot + fieldSlotSize(fld.fieldType)
  }
  lowerInsn(LReturn, ctorAsm)

  val ctorCode = assembleCode(ctorAsm, slot + 1, slot)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParams: List[JvmType] = newList()
  for fld in c.fields.toArray() {
    ctorParams.add(fld.fieldType)
  }
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParams, JVoid), ctorAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(ctorMethod)
  makeCaseClass(fullName, baseName, cfFields, methods)
}

/// Lower a union type into a list of ClassFiles:
///   index 0 — the abstract base class
///   index i+1 — case class i
pub func lowerUnion(u: in LUnion, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()

  // Base class methods
  val baseMethods: List[MethodInfo] = newList()

  // Abstract base class <init>()V — needed so case constructors can super-call
  val baseCtorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), baseCtorAsm)
  val objPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid), baseCtorAsm)
  lowerInsn(LReturn, baseCtorAsm)

  val baseCtorCode = assembleCode(baseCtorAsm, 1, 1)
  val baseCtorAttrs: List[Attribute] = newList()
  baseCtorAttrs.add(baseCtorCode)
  val baseCtorPs: List[JvmType] = newList()
  val baseCtor = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(baseCtorPs, JVoid), baseCtorAttrs)
  baseMethods.add(baseCtor)

  for fn in u.methods.toArray() {
    baseMethods.add(lowerFunc(fn, pool))
  }

  val baseFields: List[FieldInfo] = newList()
  result.add(makeAbstractClass(u.baseName, baseFields, baseMethods))

  // One concrete case class per union case
  for c in u.cases.toArray() {
    result.add(lowerCase(u.baseName, c, pool))
  }

  result
}

// ── Union match dispatch ──────────────────────────────────────────────────────
pub record LMatchArm {
  caseClass: String
  boundSlot: Int
  skipLabel: String
  bodyInsns: List[LInsn]
}

func lowerBodyInsns(asm: in MethodAssembler, insns: in List[LInsn]): Unit {
  var j = 0
  while j < insns.count {
    lowerInsn(insns[j], asm)
    j = j + 1
  }
}

// Emit an instanceof/branch/checkcast chain for each arm of a union match.
// For each arm: test instanceof caseClass; if false jump to skipLabel;
// checkcast caseClass into boundSlot; run bodyInsns; goto endLabel.
pub func lowerMatchUnion(
  asm: in MethodAssembler, scrutSlot: in Int, arms: in List[LMatchArm], endLabel: in String
): Unit {
  var i = 0
  while i < arms.count {
    val arm = arms[i]
    lowerInsn(LAload(slot = scrutSlot), asm)
    lowerInsn(LInstanceof(className = arm.caseClass), asm)
    lowerInsn(LIfeq(label = arm.skipLabel), asm)
    lowerInsn(LAload(slot = scrutSlot), asm)
    lowerInsn(LCheckcast(className = arm.caseClass), asm)
    lowerInsn(LAstore(slot = arm.boundSlot), asm)
    lowerBodyInsns(asm, arm.bodyInsns)
    lowerInsn(LGoto(label = endLabel), asm)
    lowerInsn(LLabel(name = arm.skipLabel), asm)
    i = i + 1
  }
}

// ── Int match dispatch ────────────────────────────────────────────────────────
pub record LIntArm {
  key: Int
  caseLabel: String
  bodyInsns: List[LInsn]
  // Emit a lookupswitch dispatch over integer cases.  Each arm is emitted as:
  //   caseLabel: [bodyInsns] goto endLabel
  // The default case follows all arms:
  //   defaultLabel: [defaultInsns] goto endLabel
}

pub func lowerMatchInt(
  asm: in MethodAssembler,
  scrutSlot: in Int,
  arms: in List[LIntArm],
  defaultLabel: in String,
  defaultInsns: in List[LInsn],
  endLabel: in String,
): Unit {
  val pairs: List[SwitchPair] = newList()
  var i = 0
  while i < arms.count {
    pairs.add(SwitchPair(key = arms[i].key, label = arms[i].caseLabel))
    i = i + 1
  }
  lowerInsn(LIload(slot = scrutSlot), asm)
  lowerInsn(LLookupswitch(defaultLabel = defaultLabel, pairs = pairs), asm)
  i = 0
  while i < arms.count {
    lowerInsn(LLabel(name = arms[i].caseLabel), asm)
    lowerBodyInsns(asm, arms[i].bodyInsns)
    lowerInsn(LGoto(label = endLabel), asm)
    i = i + 1
  }
  lowerInsn(LLabel(name = defaultLabel), asm)
  lowerBodyInsns(asm, defaultInsns)
  lowerInsn(LGoto(label = endLabel), asm)
}

// ── String match dispatch ─────────────────────────────────────────────────────
pub record LStrArm {
  key: String
  skipLabel: String
  bodyInsns: List[LInsn]
  // Emit a linear equals-chain dispatch over string cases.
  // For each arm: aload scrutSlot; ldc key; invokevirtual equals; ifeq skipLabel;
  //   [bodyInsns] goto endLabel; skipLabel:
  // Followed by [defaultInsns] goto endLabel.
}

pub func lowerMatchStr(
  asm: in MethodAssembler,
  scrutSlot: in Int,
  arms: in List[LStrArm],
  defaultInsns: in List[LInsn],
  endLabel: in String,
): Unit {
  val eqIdx = poolMethodref(asm.pool, "java/lang/String", "equals", "(Ljava/lang/Object;)Z")
  var i = 0
  while i < arms.count {
    lowerInsn(LAload(slot = scrutSlot), asm)
    lowerInsn(LPushString(s = arms[i].key), asm)
    emitInvokevirtual(asm, eqIdx)
    trackStack(asm, -1)
    lowerInsn(LIfeq(label = arms[i].skipLabel), asm)
    lowerBodyInsns(asm, arms[i].bodyInsns)
    lowerInsn(LGoto(label = endLabel), asm)
    lowerInsn(LLabel(name = arms[i].skipLabel), asm)
    i = i + 1
  }
  lowerBodyInsns(asm, defaultInsns)
  lowerInsn(LGoto(label = endLabel), asm)
}

// ── Closure / inner-class lowering ────────────────────────────────────────────
pub record LClosureCapture {
  captureName: String
  captureType: JvmType
}

pub record LClosure {
  closureClass: String
  ifaceClass: String
  ifaceMethod: String
  captures: List[LClosureCapture]
  methodParams: List[JvmType]
  methodRet: JvmType
  bodyInsns: List[LInsn]
  // Total local-slot count the interface-method body uses (this + the method
  // params + any locals the body allocates).  `0` means "infer from
  // `methodParams` only" (the legacy async-path shape, whose hand-built bodies
  // allocate no extra locals).  J2b general lambdas set this from the codegen
  // body ctx's slot ticker so `max_locals` covers param/capture/temporary slots.
  bodyMaxLocals: Int
}

func lowerClosureCaptures(captures: in List[LClosureCapture], pool: in Pool): List[FieldInfo] {
  val fields: List[FieldInfo] = newList()
  var i = 0
  while i < captures.count {
    val cap = captures[i]
    val emptyAttrs: List[Attribute] = newList()
    fields.add(makeFieldInfo(ACC_PRIVATE, cap.captureName, typeDescriptor(cap.captureType), emptyAttrs))
    i = i + 1
  }
  fields
}

func lowerClosureCtor(c: in LClosure, pool: in Pool): MethodInfo {
  val asm = newAssembler(pool)
  val objCtorIdx = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  emitAload(asm, 0)
  emitInvokespecial(asm, objCtorIdx)
  var slot = 1
  var i = 0
  while i < c.captures.count {
    val cap = c.captures[i]
    val capDesc = typeDescriptor(cap.captureType)
    val fIdx = poolFieldref(pool, c.closureClass, cap.captureName, capDesc)
    emitAload(asm, 0)
    match cap.captureType {
      case JInt -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JLong -> {
        emitLload(asm, slot)
        slot = slot + 2
      }
      case JFloat -> {
        emitFload(asm, slot)
        slot = slot + 1
      }
      case JDouble -> {
        emitDload(asm, slot)
        slot = slot + 2
      }
      case JBoolean -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JByte -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JChar -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JShort -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JVoid -> ()
      case JRef(_) -> {
        emitAload(asm, slot)
        slot = slot + 1
      }
      case JArray(_) -> {
        emitAload(asm, slot)
        slot = slot + 1
      }
    }
    emitPutfield(asm, fIdx)
    i = i + 1
  }
  emitReturn(asm)
  val maxL = slot
  val codeAttr = assembleCode(asm, 3, maxL)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val ctorPs: List[JvmType] = newList()
  var ci = 0
  while ci < c.captures.count {
    ctorPs.add(c.captures[ci].captureType)
    ci = ci + 1
  }
  makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), attrs)
}

func lowerClosureMethod(c: in LClosure, pool: in Pool): MethodInfo {
  // Lower the interface method through the full `lowerFuncForClass` path so the
  // body gets a real StackMapTable (branchy lambda bodies — `if` / `match` —
  // need branch-target frames) and slot pre-initialisation.  The receiver
  // (slot 0) is typed as the closure class.  `maxStack = 0` lets the assembler
  // infer the peak stack; `maxLocals` uses the codegen-supplied body count, with
  // the param-only estimate as the floor for hand-built (async-path) bodies.
  val paramSlots = 1 + slotSum(c.methodParams)
  val localCount = if c.bodyMaxLocals > paramSlots { c.bodyMaxLocals } else { paramSlots }
  val lf = LFunc(
    flags = ACC_PUBLIC,
    name = c.ifaceMethod,
    params = c.methodParams,
    ret = c.methodRet,
    insns = c.bodyInsns,
    maxStack = 0,
    maxLocals = localCount
  )
  lowerFuncForClass(lf, c.closureClass, pool)
}

pub func lowerClosure(c: in LClosure, pool: in Pool): ClassFile {
  val fields = lowerClosureCaptures(c.captures, pool)
  val ctor = lowerClosureCtor(c, pool)
  val method = lowerClosureMethod(c, pool)
  val methods: List[MethodInfo] = newList()
  methods.add(ctor)
  methods.add(method)
  val ifaces: List[String] = newList()
  ifaces.add(c.ifaceClass)
  makeClassFullWithInterfaces(c.closureClass, ifaces, fields, methods)
}

// ── Virtual-thread async helpers ──────────────────────────────────────────────
// Emits Thread.startVirtualThread(runnable) — pops Runnable, pushes Thread.
pub func lowerSpawnVirtualThread(asm: in MethodAssembler): Unit {
  val idx = poolMethodref(
    asm.pool,
    "java/lang/Thread",
    "startVirtualThread",
    "(Ljava/lang/Runnable;)Ljava/lang/Thread;"
  )
  emitInvokestatic(asm, idx)
  trackStack(asm, 0)
}

// Emits thread.join() — pops Thread ref, returns void.
pub func lowerThreadJoin(asm: in MethodAssembler): Unit {
  val idx = poolMethodref(asm.pool, "java/lang/Thread", "join", "()V")
  emitInvokevirtual(asm, idx)
  trackStack(asm, -1)
}

// ── Distinct-type lowering ────────────────────────────────────────────────────
//
// Lowers a Lyric distinct type (`type T = U`) to a plain final class with a
// single private final field `$value` of the underlying JVM type, a public
// canonical constructor, and a public `$value()` accessor.
// This is the bootstrap approximation of §6.2 (Java record shape deferred).
pub record LDistinctType {
  wrapperClass: String
  underlyingType: JvmType
}

pub func lowerDistinctType(d: in LDistinctType, pool: in Pool): ClassFile {
  val valueDesc = typeDescriptor(d.underlyingType)
  val fieldIdx = poolFieldref(pool, d.wrapperClass, "$value", valueDesc)

  // private final <underlying> $value
  val fAttrs: List[Attribute] = newList()
  val valueField = makeFieldInfo(ACC_PRIVATE + ACC_FINAL, "$value", valueDesc, fAttrs)

  // public <init>(<underlying>)V
  val ctorAsm = newAssembler(pool)
  val objCtorIdx = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  emitAload(ctorAsm, 0)
  emitInvokespecial(ctorAsm, objCtorIdx)
  emitAload(ctorAsm, 0)
  match d.underlyingType {
    case JLong -> emitLload(ctorAsm, 1)
    case JDouble -> emitDload(ctorAsm, 1)
    case JFloat -> emitFload(ctorAsm, 1)
    case JBoolean -> emitIload(ctorAsm, 1)
    case JByte -> emitIload(ctorAsm, 1)
    case JChar -> emitIload(ctorAsm, 1)
    case JShort -> emitIload(ctorAsm, 1)
    case JInt -> emitIload(ctorAsm, 1)
    case JVoid -> ()
    case JRef(_) -> emitAload(ctorAsm, 1)
    case JArray(_) -> emitAload(ctorAsm, 1)
  }
  emitPutfield(ctorAsm, fieldIdx)
  emitReturn(ctorAsm)
  val ctorMaxL = 1 + fieldSlotSize(d.underlyingType)
  val ctorCode = assembleCode(ctorAsm, 3, ctorMaxL)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorPs: List[JvmType] = newList()
  ctorPs.add(d.underlyingType)
  val ctor = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), ctorAttrs)

  // public <underlying> $value()
  val accAsm = newAssembler(pool)
  emitAload(accAsm, 0)
  emitGetfield(accAsm, fieldIdx)
  match d.underlyingType {
    case JLong -> emitLreturn(accAsm)
    case JDouble -> emitDreturn(accAsm)
    case JFloat -> emitFreturn(accAsm)
    case JBoolean -> emitIreturn(accAsm)
    case JByte -> emitIreturn(accAsm)
    case JChar -> emitIreturn(accAsm)
    case JShort -> emitIreturn(accAsm)
    case JInt -> emitIreturn(accAsm)
    case JVoid -> ()
    case JRef(_) -> emitAreturn(accAsm)
    case JArray(_) -> emitAreturn(accAsm)
  }
  val accCode = assembleCode(accAsm, fieldSlotSize(d.underlyingType), 1)
  val accAttrs: List[Attribute] = newList()
  accAttrs.add(accCode)
  val noPs: List[JvmType] = newList()
  val acc = makeMethodInfo(ACC_PUBLIC, "$value", buildDescriptor(noPs, d.underlyingType), accAttrs)

  val fields: List[FieldInfo] = newList()
  fields.add(valueField)
  val methods: List[MethodInfo] = newList()
  methods.add(ctor)
  methods.add(acc)

  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = d.wrapperClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

// ── Range-subtype lowering ────────────────────────────────────────────────────
//
// Lowers a Lyric range subtype (`type T = U range lo ..= hi`) to a final
// wrapper class extending `lowerDistinctType` with a validating constructor.
// The constructor branches to a throw of IllegalArgumentException when the
// value is outside [lo, hi].  Uses V49 (Java 5) to avoid StackMapTable
// complexity at the two branch merge points.
// Only JInt and JLong underlying types are supported.
pub record LRangeType {
  wrapperClass: String
  underlyingType: JvmType
  lo: Int
  hi: Int
}

pub func lowerRangeType(r: in LRangeType, pool: in Pool): ClassFile {
  val valueDesc = typeDescriptor(r.underlyingType)
  val fieldIdx = poolFieldref(pool, r.wrapperClass, "$value", valueDesc)
  val iaeClass = "java/lang/IllegalArgumentException"
  val iaeIdx = poolClass(pool, iaeClass)
  val iaeCtorIdx = poolMethodref(pool, iaeClass, "<init>", "(Ljava/lang/String;)V")
  val objCtorIdx = poolMethodref(pool, "java/lang/Object", "<init>", "()V")

  // private final <underlying> $value
  val fAttrs: List[Attribute] = newList()
  val valueField = makeFieldInfo(ACC_PRIVATE + ACC_FINAL, "$value", valueDesc, fAttrs)

  // public <init>(<underlying>)V  — validates lo <= value <= hi
  // Uses V49 class (set below) to avoid StackMapTable at branch merge points.
  val ctorAsm = newAssembler(pool)
  emitAload(ctorAsm, 0)
  emitInvokespecial(ctorAsm, objCtorIdx)
  match r.underlyingType {
    case JInt -> {
      emitIload(ctorAsm, 1)
      emitPushInt(ctorAsm, r.lo)
      emitIfIcmplt(ctorAsm, "ctor_fail")
      emitIload(ctorAsm, 1)
      emitPushInt(ctorAsm, r.hi)
      emitIfIcmpgt(ctorAsm, "ctor_fail")
      emitAload(ctorAsm, 0)
      emitIload(ctorAsm, 1)
    }
    case JLong -> {
      // push lo/hi as int, widen via i2l, then lcmp; iflt/ifgt fail
      emitLload(ctorAsm, 1)
      emitPushInt(ctorAsm, r.lo)
      emitI2l(ctorAsm)
      emitLcmp(ctorAsm)
      emitIflt(ctorAsm, "ctor_fail")
      emitLload(ctorAsm, 1)
      emitPushInt(ctorAsm, r.hi)
      emitI2l(ctorAsm)
      emitLcmp(ctorAsm)
      emitIfgt(ctorAsm, "ctor_fail")
      emitAload(ctorAsm, 0)
      emitLload(ctorAsm, 1)
    }
    case _ -> ()
  }
  emitPutfield(ctorAsm, fieldIdx)
  emitReturn(ctorAsm)
  emitLabel(ctorAsm, "ctor_fail")
  emitNew(ctorAsm, iaeIdx)
  emitDup(ctorAsm)
  emitPushString(ctorAsm, r.wrapperClass + " value out of range")
  emitInvokespecial(ctorAsm, iaeCtorIdx)
  emitAthrow(ctorAsm)
  val ctorMaxL = 1 + fieldSlotSize(r.underlyingType)
  val ctorCode = assembleCode(ctorAsm, 4, ctorMaxL)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorPs: List[JvmType] = newList()
  ctorPs.add(r.underlyingType)
  val ctor = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), ctorAttrs)

  // public <underlying> $value()  — identical to lowerDistinctType accessor
  val accAsm = newAssembler(pool)
  emitAload(accAsm, 0)
  emitGetfield(accAsm, fieldIdx)
  match r.underlyingType {
    case JLong -> emitLreturn(accAsm)
    case JDouble -> emitDreturn(accAsm)
    case JFloat -> emitFreturn(accAsm)
    case _ -> emitIreturn(accAsm)
  }
  val accCode = assembleCode(accAsm, fieldSlotSize(r.underlyingType), 1)
  val accAttrs: List[Attribute] = newList()
  accAttrs.add(accCode)
  val noPs: List[JvmType] = newList()
  val acc = makeMethodInfo(ACC_PUBLIC, "$value", buildDescriptor(noPs, r.underlyingType), accAttrs)

  val fields: List[FieldInfo] = newList()
  fields.add(valueField)
  val methods: List[MethodInfo] = newList()
  methods.add(ctor)
  methods.add(acc)

  ClassFile(
    minorVersion = 0,
    majorVersion = 49,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = r.wrapperClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

// ── Interface lowering ────────────────────────────────────────────────────────
//
// Lowers a Lyric `interface Iface { … }` declaration to a JVM interface
// ClassFile.  Abstract method headers are emitted with ACC_ABSTRACT; default
// method bodies (from IMFunc) are emitted as concrete MethodInfos via the
// pre-resolved LFunc list.
pub record LInterface {
  className: String
  abstractMethods: List[MethodInfo]
  concreteFuncs: List[LFunc]
}

pub func lowerInterface(i: in LInterface, pool: in Pool): ClassFile {
  val methods: List[MethodInfo] = newList()
  var ai = 0
  while ai < i.abstractMethods.count {
    val m = i.abstractMethods[ai]
    val _ = poolUtf8(pool, m.name)
    val _ = poolUtf8(pool, m.descriptor)
    methods.add(m)
    ai = ai + 1
  }
  for fn in i.concreteFuncs.toArray() {
    methods.add(lowerFunc(fn, pool))
  }
  makeInterfaceWithMethods(i.className, methods)
}

// ── Opaque-type lowering ──────────────────────────────────────────────────────
//
// Lowers a Lyric opaque type to a final class (§7 bootstrap form):
//   • Fields are private + final + synthetic with `$`-prefixed mangled names.
//   • The constructor is package-private (flag = 0; no ACC_PUBLIC).
//   • Bootstrap-grade: each field also gets a public `$<name>()T` accessor so
//     the self-test can verify field values without JVM reflection.
//     Full opacity (no accessors) is a Phase-6 deliverable.
pub record LOpaqueField {
  name: String
  fieldType: JvmType
}

pub record LOpaqueType {
  className: String
  fields: List[LOpaqueField]
  // Package-private constructor: aload_0 → Object.<init>() → for each field: aload_0, load param, putfield → return.
}

func lowerOpaqueCtor(o: in LOpaqueType, pool: in Pool): MethodInfo {
  val asm = newAssembler(pool)
  val objCtorIdx = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  emitAload(asm, 0)
  emitInvokespecial(asm, objCtorIdx)
  var slot = 1
  var i = 0
  while i < o.fields.count {
    val f = o.fields[i]
    val mangledName = "$" + f.name
    val desc = typeDescriptor(f.fieldType)
    val fIdx = poolFieldref(pool, o.className, mangledName, desc)
    emitAload(asm, 0)
    match f.fieldType {
      case JInt -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JLong -> {
        emitLload(asm, slot)
        slot = slot + 2
      }
      case JFloat -> {
        emitFload(asm, slot)
        slot = slot + 1
      }
      case JDouble -> {
        emitDload(asm, slot)
        slot = slot + 2
      }
      case JBoolean -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JByte -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JChar -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JShort -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JVoid -> ()
      case JRef(_) -> {
        emitAload(asm, slot)
        slot = slot + 1
      }
      case JArray(_) -> {
        emitAload(asm, slot)
        slot = slot + 1
      }
    }
    emitPutfield(asm, fIdx)
    i = i + 1
  }
  emitReturn(asm)
  val maxL = slot
  // this + all param slots
  val codeAttr = assembleCode(asm, 3, maxL)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val ctorPs: List[JvmType] = newList()
  var ci = 0
  while ci < o.fields.count {
    ctorPs.add(o.fields[ci].fieldType)
    ci = ci + 1
  }
  // ACC_PUBLIC: the package's own host class (`<pkg>`) and the opaque type
  // (`<pkg>/<Name>`) land in different JVM packages, so a package-private ctor
  // is inaccessible to in-package construction (`Counter(value = …)`) — it would
  // raise IllegalAccessError.  Construction-hiding from external Java is the
  // facade's job (and the reflection-sealing guarantee is a Phase-6 item, see
  // the `$<name>()` accessor note above) (J3 M-3).
  makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), attrs)
}

// One public `$<name>()T` accessor per field (bootstrap-grade; removed in Phase 6).
func lowerOpaqueAcc(className: in String, f: in LOpaqueField, pool: in Pool): MethodInfo {
  val mangledName = "$" + f.name
  val desc = typeDescriptor(f.fieldType)
  val fIdx = poolFieldref(pool, className, mangledName, desc)
  val asm = newAssembler(pool)
  emitAload(asm, 0)
  emitGetfield(asm, fIdx)
  match f.fieldType {
    case JLong -> emitLreturn(asm)
    case JDouble -> emitDreturn(asm)
    case JFloat -> emitFreturn(asm)
    case JBoolean -> emitIreturn(asm)
    case JByte -> emitIreturn(asm)
    case JChar -> emitIreturn(asm)
    case JShort -> emitIreturn(asm)
    case JInt -> emitIreturn(asm)
    case JVoid -> ()
    case JRef(_) -> emitAreturn(asm)
    case JArray(_) -> emitAreturn(asm)
  }
  val code = assembleCode(asm, fieldSlotSize(f.fieldType), 1)
  val attrs: List[Attribute] = newList()
  attrs.add(code)
  val noPs: List[JvmType] = newList()
  makeMethodInfo(ACC_PUBLIC, mangledName, buildDescriptor(noPs, f.fieldType), attrs)
}

pub func lowerOpaqueType(o: in LOpaqueType, pool: in Pool): ClassFile {
  val fields: List[FieldInfo] = newList()
  val methods: List[MethodInfo] = newList()
  var i = 0
  while i < o.fields.count {
    val f = o.fields[i]
    val mangledName = "$" + f.name
    val desc = typeDescriptor(f.fieldType)
    val fAttrs: List[Attribute] = newList()
    fields.add(makeFieldInfo(ACC_PRIVATE + ACC_FINAL + ACC_SYNTHETIC, mangledName, desc, fAttrs))
    methods.add(lowerOpaqueAcc(o.className, f, pool))
    i = i + 1
  }
  val ctor = lowerOpaqueCtor(o, pool)
  val allMethods: List[MethodInfo] = newList()
  allMethods.add(ctor)
  var j = 0
  while j < methods.count {
    allMethods.add(methods[j])
    j = j + 1
  }
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = o.className,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = fields,
    methods = allMethods,
    attrs = newList()
  )
}

// ── Q-J005: opaque-type Java interop facade ───────────────────────────────────
//
// For each LOpaqueType we emit a companion `<ClassName>$Facade` class that
// Java callers can use to construct and inspect Lyric opaque values without
// accessing the package-private constructor directly:
//
//   public static OpaqueClass create(FieldType0 f0, ...)
//   public static FieldType0   field0(OpaqueClass obj)
//   ...
//
// The facade delegates to the package-private ctor and the `$name()T` accessor
// methods already emitted by lowerOpaqueType.
func lowerOpaqueFacadeAcc(opaqueName: in String, f: in LOpaqueField, pool: in Pool): MethodInfo {
  val mangledAcc = "$" + f.name
  val noPs: List[JvmType] = newList()
  val accMethodIdx = poolMethodref(pool, opaqueName, mangledAcc, buildDescriptor(noPs, f.fieldType))
  val asm = newAssembler(pool)
  emitAload(asm, 0)
  emitInvokevirtual(asm, accMethodIdx)
  match f.fieldType {
    case JLong -> emitLreturn(asm)
    case JDouble -> emitDreturn(asm)
    case JFloat -> emitFreturn(asm)
    case JBoolean -> emitIreturn(asm)
    case JByte -> emitIreturn(asm)
    case JChar -> emitIreturn(asm)
    case JShort -> emitIreturn(asm)
    case JInt -> emitIreturn(asm)
    case JVoid -> emitReturn(asm)
    case JRef(_) -> emitAreturn(asm)
    case JArray(_) -> emitAreturn(asm)
  }
  val code = assembleCode(asm, fieldSlotSize(f.fieldType), 1)
  val attrs: List[Attribute] = newList()
  attrs.add(code)
  val pTypes: List[JvmType] = newList()
  pTypes.add(JRef(className = opaqueName))
  makeMethodInfo(ACC_PUBLIC + ACC_STATIC, f.name, buildDescriptor(pTypes, f.fieldType), attrs)
}

func lowerOpaqueFacadeFactory(o: in LOpaqueType, pool: in Pool): MethodInfo {
  val classIdx = poolClass(pool, o.className)
  val ctorPs: List[JvmType] = newList()
  var ci = 0
  while ci < o.fields.count {
    ctorPs.add(o.fields[ci].fieldType)
    ci = ci + 1
  }
  val ctorIdx = poolMethodref(pool, o.className, "<init>", buildDescriptor(ctorPs, JVoid))
  val asm = newAssembler(pool)
  emitNew(asm, classIdx)
  emitDup(asm)
  var slot = 0
  var fi = 0
  while fi < o.fields.count {
    val f = o.fields[fi]
    match f.fieldType {
      case JInt -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JLong -> {
        emitLload(asm, slot)
        slot = slot + 2
      }
      case JFloat -> {
        emitFload(asm, slot)
        slot = slot + 1
      }
      case JDouble -> {
        emitDload(asm, slot)
        slot = slot + 2
      }
      case JBoolean -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JByte -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JChar -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JShort -> {
        emitIload(asm, slot)
        slot = slot + 1
      }
      case JVoid -> ()
      case JRef(_) -> {
        emitAload(asm, slot)
        slot = slot + 1
      }
      case JArray(_) -> {
        emitAload(asm, slot)
        slot = slot + 1
      }
    }
    fi = fi + 1
  }
  emitInvokespecial(asm, ctorIdx)
  emitAreturn(asm)
  val maxLocals = slot
  val maxStack = 2 + maxLocals
  val codeAttr = assembleCode(asm, maxStack, maxLocals)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val retType: JvmType = JRef(className = o.className)
  makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "create", buildDescriptor(ctorPs, retType), attrs)
}

pub func lowerOpaqueFacade(o: in LOpaqueType, pool: in Pool): ClassFile {
  val facadeName = o.className + "$Facade"
  val methods: List[MethodInfo] = newList()
  methods.add(lowerOpaqueFacadeFactory(o, pool))
  var i = 0
  while i < o.fields.count {
    methods.add(lowerOpaqueFacadeAcc(o.className, o.fields[i], pool))
    i = i + 1
  }
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = facadeName,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = methods,
    attrs = newList()
  )
}

// ── B111: lowerSealedUnion (production sealed-interface form) ─────────────────
/// Sealed case (same shape as LUnionCase but targets the sealed-interface form).
pub record LSealedCase {
  caseName: String
  // simple case name (e.g. "Circle")
  fields: List[LField]
  // payload fields
}

pub record LSealedUnion {
  baseName: String
  // sealed interface JVM internal name
  cases: List[LSealedCase]
}

/// Lower one sealed case class: a final class implementing the sealed interface.
/// Includes a `$tag(): I` method returning the ordinal index of this case.
func lowerSealedCase(baseName: in String, c: in LSealedCase, ordinal: in Int, pool: in Pool): ClassFile {
  val fullName = caseClassName(baseName, c.caseName)

  // Fields
  val cfFields: List[FieldInfo] = newList()
  for fld in c.fields.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PUBLIC + ACC_FINAL, fld.name, typeDescriptor(fld.fieldType), fa))
  }

  // <init>(field...)V
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val superPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = superPs, ret = JVoid), ctorAsm)
  var slot = 1
  for fld in c.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    emitFieldLoad(fld.fieldType, slot, ctorAsm)
    lowerInsn(LPutfield(owner = fullName, name = fld.name, t = fld.fieldType), ctorAsm)
    slot = slot + fieldSlotSize(fld.fieldType)
  }
  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, slot + 1, slot)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParams: List[JvmType] = newList()
  for fld in c.fields.toArray() {
    ctorParams.add(fld.fieldType)
  }
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParams, JVoid), ctorAttrs)

  // $tag(): I — returns the ordinal of this case
  val tagAsm = newAssembler(pool)
  lowerInsn(LIconst(v = ordinal), tagAsm)
  lowerInsn(LIreturn, tagAsm)
  val tagCode = assembleCode(tagAsm, 1, 1)
  val tagAttrs: List[Attribute] = newList()
  tagAttrs.add(tagCode)
  val tagPs: List[JvmType] = newList()
  val tagMethod = makeMethodInfo(ACC_PUBLIC, "$tag", buildDescriptor(tagPs, JInt), tagAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(ctorMethod)
  methods.add(tagMethod)

  makeCaseClassImplementing(fullName, "java/lang/Object", baseName, cfFields, methods)
}

/// Lower a sealed union to a list of ClassFiles:
///   index 0 — the sealed interface (with PermittedSubclasses attribute)
///   index i+1 — case class i (final, implements the interface)
pub func lowerSealedUnion(u: in LSealedUnion, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()

  // Collect permitted case names
  val caseNames: List[String] = newList()
  for c in u.cases.toArray() {
    caseNames.add(caseClassName(u.baseName, c.caseName))
  }

  // Abstract $tag(): I method on the interface
  val tagAsm = newAssembler(pool)
  val tagPs: List[JvmType] = newList()
  val tagAttrs: List[Attribute] = newList()
  val tagMethod = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "$tag", buildDescriptor(tagPs, JInt), tagAttrs)
  val ifaceMethods: List[MethodInfo] = newList()
  ifaceMethods.add(tagMethod)

  result.add(makeSealedInterfaceWithMethods(u.baseName, caseNames, ifaceMethods, pool))

  var ordinal = 0
  for c in u.cases.toArray() {
    result.add(lowerSealedCase(u.baseName, c, ordinal, pool))
    ordinal = ordinal + 1
  }

  result
}

// ── B112: lowerEnum (JVM enum class) ─────────────────────────────────────────
pub record LEnumType {
  className: String
  variants: List[String]
}

/// Lower a payload-free enum type to a single JVM enum ClassFile.
pub func lowerEnum(e: in LEnumType, pool: in Pool): ClassFile {
  val cls = e.className
  val clsDesc = "L" + cls + ";"
  val arrDesc = "[" + clsDesc

  val cfFields: List[FieldInfo] = newList()

  // One public static final field per variant
  for v in e.variants.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PUBLIC + ACC_STATIC + ACC_FINAL + ACC_ENUM, v, clsDesc, fa))
  }

  // $VALUES: E[]
  val valFa: List[Attribute] = newList()
  cfFields.add(makeFieldInfo(ACC_PRIVATE + ACC_STATIC + ACC_FINAL + ACC_SYNTHETIC, "$VALUES", arrDesc, valFa))

  val methods: List[MethodInfo] = newList()

  // Private <init>(String name, int ordinal): super(name, ordinal)
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  lowerInsn(LAload(slot = 1), ctorAsm)
  // name
  lowerInsn(LIload(slot = 2), ctorAsm)
  // ordinal
  val enumPs: List[JvmType] = newList()
  enumPs.add(JRef(className = "java/lang/String"))
  enumPs.add(JInt)
  lowerInsn(LInvokespecial(owner = "java/lang/Enum", name = "<init>", params = enumPs, ret = JVoid), ctorAsm)
  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 3, 3)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorPs: List[JvmType] = newList()
  ctorPs.add(JRef(className = "java/lang/String"))
  ctorPs.add(JInt)
  methods.add(makeMethodInfo(ACC_PRIVATE, "<init>", buildDescriptor(ctorPs, JVoid), ctorAttrs))

  // <clinit>: initialise each variant field, then $VALUES array
  val clinitAsm = newAssembler(pool)
  val enumNewIdx = poolClass(pool, cls)
  val enumCtorDesc = "(Ljava/lang/String;I)V"
  val enumCtorRef = poolMethodref(pool, cls, "<init>", enumCtorDesc)
  var ordinal = 0
  for v in e.variants.toArray() {
    // new E("V", ordinal)
    lowerInsn(LNew(className = cls), clinitAsm)
    lowerInsn(LDup, clinitAsm)
    lowerInsn(LPushString(s = v), clinitAsm)
    lowerInsn(LIconst(v = ordinal), clinitAsm)
    lowerInsn(LInvokespecial(owner = cls, name = "<init>", params = ctorPs, ret = JVoid), clinitAsm)
    lowerInsn(LPutstatic(owner = cls, name = v, t = JRef(className = cls)), clinitAsm)
    ordinal = ordinal + 1
  }

  // Build $VALUES array
  lowerInsn(LIconst(v = e.variants.count), clinitAsm)
  lowerInsn(LAnewarray(className = cls), clinitAsm)
  var ai = 0
  for v in e.variants.toArray() {
    lowerInsn(LDup, clinitAsm)
    lowerInsn(LIconst(v = ai), clinitAsm)
    lowerInsn(LGetstatic(owner = cls, name = v, t = JRef(className = cls)), clinitAsm)
    lowerInsn(LAastore, clinitAsm)
    ai = ai + 1
  }
  lowerInsn(LPutstatic(owner = cls, name = "$VALUES", t = JArray(JRef(className = cls))), clinitAsm)
  lowerInsn(LReturn, clinitAsm)
  val clinitCode = assembleCode(clinitAsm, 5, 0)
  val clinitAttrs: List[Attribute] = newList()
  clinitAttrs.add(clinitCode)
  val clinitPs: List[JvmType] = newList()
  methods.add(makeMethodInfo(ACC_STATIC, "<clinit>", buildDescriptor(clinitPs, JVoid), clinitAttrs))

  // values(): E[]
  val valAsm = newAssembler(pool)
  lowerInsn(LGetstatic(owner = cls, name = "$VALUES", t = JArray(JRef(className = cls))), valAsm)
  lowerInsn(
    LInvokevirtual(
      owner = "java/lang/Object",
      name = "clone",
      params = clinitPs,
      ret = JRef(className = "java/lang/Object")
    ),
    valAsm
  )
  lowerInsn(LCheckcast(className = "[" + clsDesc), valAsm)
  lowerInsn(LAreturn, valAsm)
  val valCode = assembleCode(valAsm, 1, 0)
  val valAttrs: List[Attribute] = newList()
  valAttrs.add(valCode)
  val valRet: List[JvmType] = newList()
  methods.add(
    makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "values", buildDescriptor(valRet, JArray(JRef(className = cls))), valAttrs)
  )

  // valueOf(String): E — delegates to Enum.valueOf(Class, String)
  val voAsm = newAssembler(pool)
  emitPushClass(voAsm, cls)
  lowerInsn(LAload(slot = 0), voAsm)
  val voPs: List[JvmType] = newList()
  voPs.add(JRef(className = "java/lang/Class"))
  voPs.add(JRef(className = "java/lang/String"))
  lowerInsn(
    LInvokestatic(owner = "java/lang/Enum", name = "valueOf", params = voPs, ret = JRef(className = "java/lang/Enum")),
    voAsm
  )
  lowerInsn(LCheckcast(className = cls), voAsm)
  lowerInsn(LAreturn, voAsm)
  val voCode = assembleCode(voAsm, 2, 1)
  val voAttrs: List[Attribute] = newList()
  voAttrs.add(voCode)
  val voParamPs: List[JvmType] = newList()
  voParamPs.add(JRef(className = "java/lang/String"))
  methods.add(
    makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "valueOf", buildDescriptor(voParamPs, JRef(className = cls)), voAttrs)
  )

  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL + ACC_ENUM,
    thisClass = cls,
    superClass = "java/lang/Enum",
    interfaces = newList(),
    fields = cfFields,
    methods = methods,
    attrs = newList()
  )
}

// ── B114: lowerNatTag (phantom N_<value> class for value generics) ────────────
pub record LNatTag {
  className: String
  // e.g. "N_42"
  value: Long
}

/// Lower a nat-tag phantom class with a public static final long VALUE field
/// and a value() accessor.
pub func lowerNatTag(n: in LNatTag, pool: in Pool): ClassFile {
  val cls = n.className
  val longDesc = typeDescriptor(JLong)
  val cfFields: List[FieldInfo] = newList()
  val fa: List[Attribute] = newList()
  cfFields.add(makeFieldInfo(ACC_PUBLIC + ACC_STATIC + ACC_FINAL, "VALUE", longDesc, fa))

  val methods: List[MethodInfo] = newList()

  // <clinit>: VALUE = n.value
  val clinitAsm = newAssembler(pool)
  lowerInsn(LLconst(v = n.value), clinitAsm)
  lowerInsn(LPutstatic(owner = cls, name = "VALUE", t = JLong), clinitAsm)
  lowerInsn(LReturn, clinitAsm)
  val clinitPs: List[JvmType] = newList()
  val clinitCode = assembleCode(clinitAsm, 2, 0)
  val clinitAttrs: List[Attribute] = newList()
  clinitAttrs.add(clinitCode)
  methods.add(makeMethodInfo(ACC_STATIC, "<clinit>", buildDescriptor(clinitPs, JVoid), clinitAttrs))

  // public long value() { return VALUE; }
  val accAsm = newAssembler(pool)
  lowerInsn(LGetstatic(owner = cls, name = "VALUE", t = JLong), accAsm)
  lowerInsn(LLreturn, accAsm)
  val accPs: List[JvmType] = newList()
  val accCode = assembleCode(accAsm, 2, 1)
  val accAttrs: List[Attribute] = newList()
  accAttrs.add(accCode)
  methods.add(makeMethodInfo(ACC_PUBLIC, "value", buildDescriptor(accPs, JLong), accAttrs))

  // Default <init>
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val objPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid), ctorAsm)
  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 1, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorPs: List[JvmType] = newList()
  methods.add(makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), ctorAttrs))

  makeFinalClass(cls, cfFields, methods)
}

// ── B115: makeLyricSignatureAttr ──────────────────────────────────────────────
/// Build a `LyricSignature` vendor attribute whose info bytes are the
/// modified-UTF-8 encoding of `sig`.
pub func makeLyricSignatureAttr(sig: in String): Attribute {
  val w = writerNew()
  writerModifiedUtf8(w, sig)
  attrFromWriter("LyricSignature", w)
}

// ── B116: lowerExposedRecord (unmangled fields + Record class attribute) ───────
pub record LExposedRecord {
  className: String
  fields: List[LField]
}

/// Lower an `exposed record` to a ClassFile:
/// - ACC_PUBLIC + ACC_SUPER + ACC_FINAL, superClass = java/lang/Record
/// - Fields are NOT name-mangled (no `$` prefix)
/// - Unmangled public accessor methods named after each field
/// - A `Record` class-level attribute listing all components
pub func lowerExposedRecord(r: in LExposedRecord, pool: in Pool): ClassFile {
  val cfFields: List[FieldInfo] = newList()
  val methods: List[MethodInfo] = newList()
  val fieldNames: List[String] = newList()
  val fieldDescs: List[String] = newList()

  for fld in r.fields.toArray() {
    val desc = typeDescriptor(fld.fieldType)
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PRIVATE + ACC_FINAL, fld.name, desc, fa))
    fieldNames.add(fld.name)
    fieldDescs.add(desc)
  }

  // <init>(fields...)V
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val recPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Record", name = "<init>", params = recPs, ret = JVoid), ctorAsm)
  var slot = 1
  for fld in r.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    emitFieldLoad(fld.fieldType, slot, ctorAsm)
    lowerInsn(LPutfield(owner = r.className, name = fld.name, t = fld.fieldType), ctorAsm)
    slot = slot + fieldSlotSize(fld.fieldType)
  }
  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, slot + 1, slot)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParams: List[JvmType] = newList()
  for fld in r.fields.toArray() {
    ctorParams.add(fld.fieldType)
  }
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParams, JVoid), ctorAttrs)
  methods.add(ctorMethod)

  // Unmangled public accessor: <name>(): <type>
  for fld in r.fields.toArray() {
    val accAsm = newAssembler(pool)
    lowerInsn(LAload(slot = 0), accAsm)
    lowerInsn(LGetfield(owner = r.className, name = fld.name, t = fld.fieldType), accAsm)
    lowerInsn(returnInsn(fld.fieldType), accAsm)
    val accPs: List[JvmType] = newList()
    val accCode = assembleCode(accAsm, fieldSlotSize(fld.fieldType) + 1, 1)
    val accAttrs: List[Attribute] = newList()
    accAttrs.add(accCode)
    methods.add(makeMethodInfo(ACC_PUBLIC, fld.name, buildDescriptor(accPs, fld.fieldType), accAttrs))
  }

  val recAttr = makeRecordAttr(fieldNames, fieldDescs, pool)
  makeRecordClass(r.className, cfFields, methods, recAttr)
}

// ── B117: lowerProjectable (@projectable opaque + view twin + toView()) ────────
pub record LProjectable {
  opaqueTypeName: String
  viewTypeName: String
  fields: List[LOpaqueField]
}

/// Lower a `@projectable` opaque type:
///   Returns [opaqueClass, viewClass]
///   The opaque class gets a `toView(): ViewType` method that copies $-mangled
///   fields into a fresh exposed-record instance of the view type.
pub func lowerProjectable(p: in LProjectable, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()

  // Build the view type as an exposed record (unmangled fields)
  val viewFields: List[LField] = newList()
  for f in p.fields.toArray() {
    viewFields.add(LField(flags = ACC_PUBLIC, name = f.name, fieldType = f.fieldType))
  }
  val viewRec = LExposedRecord(className = p.viewTypeName, fields = viewFields)
  val viewCf = lowerExposedRecord(viewRec, pool)

  // Build the opaque type with the base lowerOpaqueType helper
  val opaqueType = LOpaqueType(className = p.opaqueTypeName, fields = p.fields)
  val opaqueCf = lowerOpaqueType(opaqueType, pool)

  // Build toView(): ViewType — copies $-mangled fields to a new ViewType instance
  val viewAsm = newAssembler(pool)
  val viewNewIdx = poolClass(pool, p.viewTypeName)
  lowerInsn(LNew(className = p.viewTypeName), viewAsm)
  lowerInsn(LDup, viewAsm)

  // Push each field value: aload_0; getfield $name
  for f in p.fields.toArray() {
    lowerInsn(LAload(slot = 0), viewAsm)
    lowerInsn(LGetfield(owner = p.opaqueTypeName, name = "$" + f.name, t = f.fieldType), viewAsm)
  }

  // Build constructor descriptor for ViewType(<fields>...)V
  val viewCtorParams: List[JvmType] = newList()
  for f in p.fields.toArray() {
    viewCtorParams.add(f.fieldType)
  }
  lowerInsn(LInvokespecial(owner = p.viewTypeName, name = "<init>", params = viewCtorParams, ret = JVoid), viewAsm)
  lowerInsn(LAreturn, viewAsm)

  val toViewPs: List[JvmType] = newList()
  var viewMaxStack = 2
  for f in p.fields.toArray() {
    viewMaxStack = viewMaxStack + fieldSlotSize(f.fieldType)
  }
  val toViewCode = assembleCode(viewAsm, viewMaxStack, 1)
  val toViewAttrs: List[Attribute] = newList()
  toViewAttrs.add(toViewCode)
  val toViewMethod = makeMethodInfo(
    ACC_PUBLIC,
    "toView",
    buildDescriptor(toViewPs, JRef(className = p.viewTypeName)),
    toViewAttrs
  )

  // Patch the opaque ClassFile to add toView()
  val opaqueMethods: List[MethodInfo] = newList()
  for m in opaqueCf.methods.toArray() {
    opaqueMethods.add(m)
  }
  opaqueMethods.add(toViewMethod)

  val opaqueWithView = ClassFile(
    minorVersion = opaqueCf.minorVersion,
    majorVersion = opaqueCf.majorVersion,
    flags = opaqueCf.flags,
    thisClass = opaqueCf.thisClass,
    superClass = opaqueCf.superClass,
    interfaces = opaqueCf.interfaces,
    fields = opaqueCf.fields,
    methods = opaqueMethods,
    attrs = opaqueCf.attrs
  )

  result.add(opaqueWithView)
  result.add(viewCf)
  result
}

// ── #3044: lowerProjectableType (@projectable opaque + view twin, full form) ──
//
// Full-feature JVM counterpart of the MSIL `lowerMOpaque` projectable path
// (PR #3015, D-progress-492): `@hidden` suppression, `@projectionBoundary`
// type preservation, nested-view recursion, and `tryInto()` synthesis.
// Supersedes the basic B117 `lowerProjectable` above (kept for the
// emission-library self-test) on the user compile pipeline.
pub record LProjFieldInfo {
  name: String
  // Declared (opaque storage) type.
  fieldType: JvmType
  // @hidden — stored on the opaque, omitted from the view.
  hidden: Bool
  // @projectionBoundary — the view field keeps the source opaque type.
  boundary: Bool
  // Some(view class) when the field's type is a non-boundary projectable
  // (the view field substitutes the nested view and toView() recurses).
  nestedViewClass: Option[String]
}

pub record LProjectableType {
  opaqueClassName: String
  viewClassName: String
  fields: List[LProjFieldInfo]
  // True when no field is @hidden and no visible field is a non-boundary
  // nested projectable — the conditions under which the view can reconstruct
  // the opaque (mirrors the MSIL canEmitTryInto eligibility).
  emitTryInto: Bool
}

// The view field's declared type: a boundary field keeps the source opaque
// type; a nested projectable substitutes its view class; all else unchanged.
pub func projViewFieldType(f: in LProjFieldInfo): JvmType {
  if f.boundary {
    f.fieldType
  } else {
    match f.nestedViewClass {
      case Some(v) -> JRef(className = v)
      case None -> f.fieldType
    }
  }
}

// `tryInto()` wraps the reconstructed opaque in `Std.Core.Result.Ok`; the
// erased case-class shapes come from `lowerUnion` / `lowerSealedCase`
// (public ctor `(Ljava/lang/Object;)V`, sealed interface base).
func projResultBase(): String {
  "Std/Core/Result"
}

func projResultOk(): String {
  "Std/Core/Result$Ok"
}

/// Lower a full-feature `@projectable` opaque type to its ClassFiles:
///   index 0 — the opaque class (private `$`-mangled fields, accessors, ctor,
///             plus a `toView(): <Name>View` instance method)
///   index 1 — the `<Name>View` class (public final fields per visible field,
///             an all-fields ctor, and — when `emitTryInto` — a
///             `tryInto(): Std.Core.Result` method reconstructing the opaque)
pub func lowerProjectableType(p: in LProjectableType, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()

  val visible: List[LProjFieldInfo] = newList()
  for f in p.fields.toArray() {
    if not f.hidden {
      visible.add(f)
    }
  }

  // ── Opaque class: base form + toView() ────────────────────────────────────
  val allFields: List[LOpaqueField] = newList()
  for f in p.fields.toArray() {
    allFields.add(LOpaqueField(name = f.name, fieldType = f.fieldType))
  }
  val opaqueCf = lowerOpaqueType(LOpaqueType(className = p.opaqueClassName, fields = allFields), pool)

  // toView(): new <Name>View; dup; per visible field: aload_0, getfield
  // $<name>, then — for a non-boundary nested projectable — invokevirtual
  // <FieldClass>.toView() so the view holds the nested view; finally
  // invokespecial <Name>View.<init>(viewFieldTypes)V.
  val tvAsm = newAssembler(pool)
  lowerInsn(LNew(className = p.viewClassName), tvAsm)
  lowerInsn(LDup, tvAsm)
  val viewCtorParams: List[JvmType] = newList()
  for f in visible.toArray() {
    lowerInsn(LAload(slot = 0), tvAsm)
    lowerInsn(LGetfield(owner = p.opaqueClassName, name = "$" + f.name, t = f.fieldType), tvAsm)
    match f.nestedViewClass {
      case Some(v) -> {
        val srcCls = match f.fieldType {
          case JRef(c) -> c
          case _ -> panic("Jvm.Lowering: nested projectable field '" + f.name + "' is not a reference type")
        }
        val noPs: List[JvmType] = newList()
        lowerInsn(LInvokevirtual(owner = srcCls, name = "toView", params = noPs, ret = JRef(className = v)), tvAsm)
      }
      case None -> ()
    }
    viewCtorParams.add(projViewFieldType(f))
  }
  lowerInsn(LInvokespecial(owner = p.viewClassName, name = "<init>", params = viewCtorParams, ret = JVoid), tvAsm)
  lowerInsn(LAreturn, tvAsm)
  var tvStack = 3
  for f in visible.toArray() {
    tvStack = tvStack + fieldSlotSize(projViewFieldType(f))
  }
  val tvCode = assembleCode(tvAsm, tvStack, 1)
  val tvAttrs: List[Attribute] = newList()
  tvAttrs.add(tvCode)
  val tvPs: List[JvmType] = newList()
  val toViewMethod = makeMethodInfo(
    ACC_PUBLIC,
    "toView",
    buildDescriptor(tvPs, JRef(className = p.viewClassName)),
    tvAttrs
  )

  val opaqueMethods: List[MethodInfo] = newList()
  for m in opaqueCf.methods.toArray() {
    opaqueMethods.add(m)
  }
  opaqueMethods.add(toViewMethod)
  result.add(
    ClassFile(
      minorVersion = opaqueCf.minorVersion,
      majorVersion = opaqueCf.majorVersion,
      flags = opaqueCf.flags,
      thisClass = opaqueCf.thisClass,
      superClass = opaqueCf.superClass,
      interfaces = opaqueCf.interfaces,
      fields = opaqueCf.fields,
      methods = opaqueMethods,
      attrs = opaqueCf.attrs
    )
  )

  // ── View class: public final fields + all-fields ctor (+ tryInto()) ───────
  val viewFields: List[FieldInfo] = newList()
  for f in visible.toArray() {
    val fa: List[Attribute] = newList()
    viewFields.add(makeFieldInfo(ACC_PUBLIC + ACC_FINAL, f.name, typeDescriptor(projViewFieldType(f)), fa))
  }

  val vcAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), vcAsm)
  val superPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = superPs, ret = JVoid), vcAsm)
  var vcSlot = 1
  for f in visible.toArray() {
    val vty = projViewFieldType(f)
    lowerInsn(LAload(slot = 0), vcAsm)
    emitFieldLoad(vty, vcSlot, vcAsm)
    lowerInsn(LPutfield(owner = p.viewClassName, name = f.name, t = vty), vcAsm)
    vcSlot = vcSlot + fieldSlotSize(vty)
  }
  lowerInsn(LReturn, vcAsm)
  val vcCode = assembleCode(vcAsm, vcSlot + 1, vcSlot)
  val vcAttrs: List[Attribute] = newList()
  vcAttrs.add(vcCode)
  val viewCtorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(viewCtorParams, JVoid), vcAttrs)

  val viewMethods: List[MethodInfo] = newList()
  viewMethods.add(viewCtorMethod)

  if p.emitTryInto {
    // tryInto(): reconstruct the opaque from the view fields (eligibility
    // guarantees every opaque field is visible and view-typed identically),
    // then wrap in Std.Core.Result.Ok.  Straight-line code, so no
    // StackMapTable frames are required.  The Result classes resolve lazily
    // at first invocation, matching the JVM's per-method linking model.
    val tiAsm = newAssembler(pool)
    lowerInsn(LNew(className = projResultOk()), tiAsm)
    lowerInsn(LDup, tiAsm)
    lowerInsn(LNew(className = p.opaqueClassName), tiAsm)
    lowerInsn(LDup, tiAsm)
    val opaqueCtorParams: List[JvmType] = newList()
    for f in visible.toArray() {
      lowerInsn(LAload(slot = 0), tiAsm)
      lowerInsn(LGetfield(owner = p.viewClassName, name = f.name, t = projViewFieldType(f)), tiAsm)
      opaqueCtorParams.add(f.fieldType)
    }
    lowerInsn(LInvokespecial(owner = p.opaqueClassName, name = "<init>", params = opaqueCtorParams, ret = JVoid), tiAsm)
    val okPs: List[JvmType] = newList()
    okPs.add(JRef(className = "java/lang/Object"))
    lowerInsn(LInvokespecial(owner = projResultOk(), name = "<init>", params = okPs, ret = JVoid), tiAsm)
    lowerInsn(LAreturn, tiAsm)
    var tiStack = 5
    for f in visible.toArray() {
      tiStack = tiStack + fieldSlotSize(f.fieldType)
    }
    val tiCode = assembleCode(tiAsm, tiStack, 1)
    val tiAttrs: List[Attribute] = newList()
    tiAttrs.add(tiCode)
    val tiPs: List[JvmType] = newList()
    viewMethods.add(
      makeMethodInfo(ACC_PUBLIC, "tryInto", buildDescriptor(tiPs, JRef(className = projResultBase())), tiAttrs)
    )
  }

  result.add(
    ClassFile(
      minorVersion = 0,
      majorVersion = 65,
      flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
      thisClass = p.viewClassName,
      superClass = "java/lang/Object",
      interfaces = newList(),
      fields = viewFields,
      methods = viewMethods,
      attrs = newList()
    )
  )

  result
}

// ── B118: lowerProtectedWithBarriers (when: Condition-variable barriers) ───────
pub record LBarrierEntry {
  entryFunc: LFunc
  // the wrapped entry method (body insns only; no lock/unlock)
  conditionName: String
  // name for the Condition field (e.g. "_cond_push")
  predicateInsns: List[LInsn]
  // pushes Bool: 1=can proceed, 0=must wait
}

pub record LProtectedWithBarriers {
  className: String
  fields: List[LField]
  barriers: List[LBarrierEntry]
}

/// Lower a protected type with `when:` Condition-variable barriers.
/// Uses ReentrantLock + one Condition per barrier entry.
/// Entry method pattern: lock, while !predicate { condition.await }, body, signalAll, unlock.
pub func lowerProtectedWithBarriers(p: in LProtectedWithBarriers, pool: in Pool): ClassFile {
  val lockType = JRef(className = "java/util/concurrent/locks/ReentrantLock")
  val condType = JRef(className = "java/util/concurrent/locks/Condition")
  val methods: List[MethodInfo] = newList()
  val cfFields: List[FieldInfo] = newList()

  // _lock field
  val lockFa: List[Attribute] = newList()
  cfFields.add(makeFieldInfo(ACC_PRIVATE, "_lock", typeDescriptor(lockType), lockFa))

  // One Condition field per barrier
  for be in p.barriers.toArray() {
    val condFa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PRIVATE, be.conditionName, typeDescriptor(condType), condFa))
  }

  // Data fields
  for fld in p.fields.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(ACC_PRIVATE, fld.name, typeDescriptor(fld.fieldType), fa))
  }

  // Constructor: <init>()V — init lock, conditions, zero-init data
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val objPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid), ctorAsm)

  // new ReentrantLock(); putfield _lock
  lowerInsn(LAload(slot = 0), ctorAsm)
  lowerInsn(LNew(className = "java/util/concurrent/locks/ReentrantLock"), ctorAsm)
  lowerInsn(LDup, ctorAsm)
  val rlPs: List[JvmType] = newList()
  lowerInsn(
    LInvokespecial(owner = "java/util/concurrent/locks/ReentrantLock", name = "<init>", params = rlPs, ret = JVoid),
    ctorAsm
  )
  lowerInsn(LPutfield(owner = p.className, name = "_lock", t = lockType), ctorAsm)

  // For each barrier: _lock.newCondition() → condition field
  for be in p.barriers.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    lowerInsn(LAload(slot = 0), ctorAsm)
    lowerInsn(LGetfield(owner = p.className, name = "_lock", t = lockType), ctorAsm)
    val ncPs: List[JvmType] = newList()
    lowerInsn(
      LInvokevirtual(
        owner = "java/util/concurrent/locks/ReentrantLock",
        name = "newCondition",
        params = ncPs,
        ret = condType
      ),
      ctorAsm
    )
    lowerInsn(LPutfield(owner = p.className, name = be.conditionName, t = condType), ctorAsm)
  }

  // Zero-init data fields
  for fld in p.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    match fld.fieldType {
      case JInt -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JLong -> {
        lowerInsn(LIconst(v = 0), ctorAsm)
        lowerInsn(LI2l, ctorAsm)
      }
      case JRef(_) -> lowerInsn(LAconstNull, ctorAsm)
      case _ -> lowerInsn(LIconst(v = 0), ctorAsm)
    }
    match fld.fieldType {
      case JVoid -> ()
      case _ -> lowerInsn(LPutfield(owner = p.className, name = fld.name, t = fld.fieldType), ctorAsm)
    }
  }

  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 4, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamsEmpty: List[JvmType] = newList()
  methods.add(makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParamsEmpty, JVoid), ctorAttrs))

  // Entry methods with barrier guard
  val lockPs: List[JvmType] = newList()
  val noPs: List[JvmType] = newList()
  for be in p.barriers.toArray() {
    val ef = be.entryFunc
    val wInsns: List[LInsn] = newList()

    // Pre-initialize the result slot so that StackMapTable frames at barrier branch
    // targets (which appear before the result is stored) declare the slot as live.
    val resultSlot = ef.maxLocals
    if fieldSlotSize(ef.ret) > 0 {
      match ef.ret {
        case JLong -> {
          wInsns.add(LLconst(v = 0i64))
          wInsns.add(LLstore(slot = resultSlot))
        }
        case JDouble -> {
          wInsns.add(LDconst(v = 0.0))
          wInsns.add(LDstore(slot = resultSlot))
        }
        case JFloat -> {
          wInsns.add(LFconst(v = 0.0))
          wInsns.add(LFstore(slot = resultSlot))
        }
        case JRef(cls) -> {
          wInsns.add(LAconstNull)
          wInsns.add(LAstoreAs(slot = resultSlot, className = cls))
        }
        case JArray(_) -> {
          wInsns.add(LAconstNull)
          wInsns.add(LAstore(slot = resultSlot))
        }
        case _ -> {
          wInsns.add(LIconst(v = 0))
          wInsns.add(LIstore(slot = resultSlot))
        }
      }
    }

    // lock.lock()
    wInsns.add(LAload(slot = 0))
    wInsns.add(LGetfield(owner = p.className, name = "_lock", t = lockType))
    wInsns.add(
      LInvokevirtual(owner = "java/util/concurrent/locks/ReentrantLock", name = "lock", params = lockPs, ret = JVoid)
    )

    // while !predicate() { condition.await() }  (no exception handling for bootstrap)
    wInsns.add(LLabel(name = "barrier_check_" + be.conditionName))
    var pi = 0
    while pi < be.predicateInsns.count {
      wInsns.add(be.predicateInsns[pi])
      pi = pi + 1
    }
    wInsns.add(LIfne(label = "barrier_body_" + be.conditionName))
    // await
    wInsns.add(LAload(slot = 0))
    wInsns.add(LGetfield(owner = p.className, name = be.conditionName, t = condType))
    val awaitPs: List[JvmType] = newList()
    wInsns.add(
      LInvokeinterface(
        owner = "java/util/concurrent/locks/Condition",
        name = "awaitUninterruptibly",
        params = awaitPs,
        ret = JVoid,
        argCount = 1
      )
    )
    wInsns.add(LGoto(label = "barrier_check_" + be.conditionName))
    wInsns.add(LLabel(name = "barrier_body_" + be.conditionName))

    // Body
    var bi = 0
    while bi < ef.insns.count {
      wInsns.add(ef.insns[bi])
      bi = bi + 1
    }

    // Save result if non-void
    if fieldSlotSize(ef.ret) > 0 {
      wInsns.add(storeInsn(ef.ret, resultSlot))
    }

    // signalAll on the condition
    wInsns.add(LAload(slot = 0))
    wInsns.add(LGetfield(owner = p.className, name = be.conditionName, t = condType))
    val sigPs: List[JvmType] = newList()
    wInsns.add(
      LInvokeinterface(
        owner = "java/util/concurrent/locks/Condition",
        name = "signalAll",
        params = sigPs,
        ret = JVoid,
        argCount = 1
      )
    )

    // lock.unlock()
    wInsns.add(LAload(slot = 0))
    wInsns.add(LGetfield(owner = p.className, name = "_lock", t = lockType))
    wInsns.add(
      LInvokevirtual(owner = "java/util/concurrent/locks/ReentrantLock", name = "unlock", params = lockPs, ret = JVoid)
    )

    // Return result
    if fieldSlotSize(ef.ret) > 0 {
      wInsns.add(loadInsn(ef.ret, resultSlot))
    }
    wInsns.add(returnInsn(ef.ret))

    val wFunc = LFunc(
      flags = ef.flags,
      name = ef.name,
      params = ef.params,
      ret = ef.ret,
      insns = wInsns,
      maxStack = ef.maxStack + 3,
      maxLocals = ef.maxLocals + fieldSlotSize(ef.ret)
    )
    methods.add(lowerFuncForClass(wFunc, p.className, pool))
  }

  makeFinalClass(p.className, cfFields, methods)
}

// ── B119: lowerHotAsync (CompletableFuture thenCompose chain) ────────────────
pub record LHotFunc {
  className: String
  // host class for the async method
  methodName: String
  // name of the async method
  resultType: JvmType
  // the T in CompletableFuture<T>
  stage1Insns: List[LInsn]
  // first stage: pushes the initial value (no return)
  stage2Insns: List[LInsn]
  // second stage: pops one slot, pushes the result (no return)
}

/// Bootstrap-grade lowering of a two-stage @hot async function.
/// Emits a static `methodName(): CompletableFuture<T>` on the host class.
/// Stage 1 result → completedFuture; stage 2 applied via thenApply closure.
pub func lowerHotAsync(h: in LHotFunc, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()
  val cfType = JRef(className = "java/util/concurrent/CompletableFuture")

  // Closure class that implements Function<Object,Object>
  // apply(Object) executes stage2Insns on the input value and returns the result.
  // thenApply uses this to transform the stage1 result to the final result.
  val appInsns: List[LInsn] = newList()
  // stage2Insns expect the arg on stack; slot 1 = the Object argument
  appInsns.add(LAload(slot = 1))
  // push Object arg
  var s2i = 0
  while s2i < h.stage2Insns.count {
    appInsns.add(h.stage2Insns[s2i])
    s2i = s2i + 1
  }
  // Return the result directly (must be an Object on the stack after stage2Insns)
  appInsns.add(LAreturn)

  val appCaptures: List[LClosureCapture] = newList()
  val appParams: List[JvmType] = newList()
  appParams.add(JRef(className = "java/lang/Object"))

  val applyFuncClass = h.className + "$Stage2"
  val appClosure = LClosure(
    closureClass = applyFuncClass,
    ifaceClass = "java/util/function/Function",
    ifaceMethod = "apply",
    captures = appCaptures,
    methodParams = appParams,
    methodRet = JRef(className = "java/lang/Object"),
    bodyInsns = appInsns,
    bodyMaxLocals = 0
  )
  result.add(lowerClosure(appClosure, pool))

  // Host class with static async method
  val hostAsm = newAssembler(pool)

  // Execute stage1, wrap in completedFuture
  var s1i = 0
  while s1i < h.stage1Insns.count {
    lowerInsn(h.stage1Insns[s1i], hostAsm)
    s1i = s1i + 1
  }
  // stage1 must push an Object (box int for bootstrap)
  val cfPs1: List[JvmType] = newList()
  cfPs1.add(JRef(className = "java/lang/Object"))
  lowerInsn(
    LInvokestatic(
      owner = "java/util/concurrent/CompletableFuture",
      name = "completedFuture",
      params = cfPs1,
      ret = cfType
    ),
    hostAsm
  )
  // .thenCompose(new Stage2())
  lowerInsn(LNew(className = applyFuncClass), hostAsm)
  lowerInsn(LDup, hostAsm)
  val stage2CtorPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = applyFuncClass, name = "<init>", params = stage2CtorPs, ret = JVoid), hostAsm)
  val thenPs: List[JvmType] = newList()
  thenPs.add(JRef(className = "java/util/function/Function"))
  lowerInsn(
    LInvokevirtual(owner = "java/util/concurrent/CompletableFuture", name = "thenApply", params = thenPs, ret = cfType),
    hostAsm
  )
  lowerInsn(LAreturn, hostAsm)

  val hostPs: List[JvmType] = newList()
  val hostCode = assembleCode(hostAsm, 4, 0)
  val hostAttrs: List[Attribute] = newList()
  hostAttrs.add(hostCode)
  val hostMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, h.methodName, buildDescriptor(hostPs, cfType), hostAttrs)
  val hostMethods: List[MethodInfo] = newList()
  hostMethods.add(hostMethod)
  result.add(makeClassWithMethods(h.className, hostMethods))
  result
}

// ── B129: lowerAsyncGenerator (Iterable<Object>+Iterator<Object> collect-all) ─
pub record LGenParam {
  paramName: String
  paramType: JvmType
}

/// Descriptor for a Lyric async-generator function.
pub record LGenFunc {
  /// Binary name of the synthesised generator class, e.g. "com/example/Doubles$Gen".
  generatorClass: String
  /// Binary name of the host class that receives the static kickoff method.
  hostClass: String
  /// Name of the static kickoff method on `hostClass`.
  methodName: String
  /// JVM type of each yielded element (used to decide whether to box).
  elemType: JvmType
  /// Parameters captured from the callsite into generator fields.
  params: List[LGenParam]
  /// Body instructions for RunBody.
  /// `LYield` is a meta-insn: the preceding instructions must have left one
  /// value on the stack; lowerAsyncGenerator replaces it with ArrayList.add.
  bodyInsns: List[LInsn]
}

/// Lazy lowering of a Lyric `async func` with `yield`.
///
/// Emits a generator class implementing `java.lang.Iterable<Object>`,
/// `java.util.Iterator<Object>`, and `java.lang.Runnable`.  The body runs
/// in a JDK-21+ virtual thread; each `yield` calls `SynchronousQueue.put`
/// to hand the value to the consumer; `hasNext` calls `take` to receive the
/// next value or the sentinel.  This gives truly lazy, on-demand evaluation:
/// values are produced only when the consumer calls `hasNext`.
///
/// Class layout:
///   static _DONE_SENTINEL: Object            — signals exhaustion
///   _done: boolean                           — true after sentinel received
///   _pending: Object                         — buffered value from last hasNext
///   _channel: SynchronousQueue<Object>       — producer↔consumer handoff
///   _param0 … _paramN: captured params
///
/// Methods:
///   <clinit>:  new Object(); putstatic _DONE_SENTINEL
///   <init>(params): super(); store params to fields
///   run():     body with yield → channel.put(value); sentinel put at end;
///              InterruptedException caught and silently swallows (consumer abandoned)
///   iterator(): new SynchronousQueue; reset _done/_pending; startVirtualThread(this)
///   hasNext(): if _done return false; take from channel; check sentinel; store pending
///   next():    return _pending
///
/// Uses class file version 49 (Java 5) so no StackMapTable is required for
/// the branches in hasNext() and run().  Virtual threads and SynchronousQueue
/// are JDK-21+ runtime APIs callable from any class file version.
pub func lowerAsyncGenerator(g: in LGenFunc, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()
  val genClass = g.generatorClass
  val objClass = "java/lang/Object"
  val sqClass = "java/util/concurrent/SynchronousQueue"
  val iterClass = "java/util/Iterator"
  val iterableClass = "java/lang/Iterable"
  val runnableClass = "java/lang/Runnable"
  val threadClass = "java/lang/Thread"
  val objType = JRef(className = objClass)
  val sqType = JRef(className = sqClass)

  // ── 1. Field declarations ──────────────────────────────────────────────────
  val emptyAttrs: List[Attribute] = newList()
  val sentinelDesc = typeDescriptor(objType)
  val doneDesc = "Z"
  val pendingDesc = typeDescriptor(objType)
  val channelDesc = typeDescriptor(sqType)

  val fieldsOut: List[FieldInfo] = newList()
  // Static sentinel signals exhaustion to the consumer.
  fieldsOut.add(makeFieldInfo(ACC_PRIVATE + ACC_STATIC + ACC_FINAL, "_DONE_SENTINEL", sentinelDesc, emptyAttrs))
  // Instance fields
  fieldsOut.add(makeFieldInfo(ACC_PRIVATE, "_done", doneDesc, emptyAttrs))
  fieldsOut.add(makeFieldInfo(ACC_PRIVATE, "_pending", pendingDesc, emptyAttrs))
  fieldsOut.add(makeFieldInfo(ACC_PRIVATE, "_channel", channelDesc, emptyAttrs))
  var pi = 0
  while pi < g.params.count {
    val p = g.params[pi]
    val pAttrs: List[Attribute] = newList()
    fieldsOut.add(makeFieldInfo(ACC_PUBLIC, p.paramName, typeDescriptor(p.paramType), pAttrs))
    pi = pi + 1
  }

  // Pre-compute constant pool refs used across multiple methods.
  val objCtorIdx = poolMethodref(pool, objClass, "<init>", "()V")
  val sqCtorIdx = poolMethodref(pool, sqClass, "<init>", "()V")
  val sentinelIdx = poolFieldref(pool, genClass, "_DONE_SENTINEL", sentinelDesc)
  val doneIdx = poolFieldref(pool, genClass, "_done", doneDesc)
  val pendingIdx = poolFieldref(pool, genClass, "_pending", pendingDesc)
  val channelIdx = poolFieldref(pool, genClass, "_channel", channelDesc)

  // ── 2. <clinit> — initialize _DONE_SENTINEL ───────────────────────────────
  val clinitAsm = newAssembler(pool)
  emitNew(clinitAsm, poolClass(pool, objClass))
  emitDup(clinitAsm)
  emitInvokespecial(clinitAsm, objCtorIdx)
  emitPutstatic(clinitAsm, sentinelIdx)
  emitReturn(clinitAsm)
  val clinitCode = assembleCode(clinitAsm, 2, 0)
  val clinitAttrs: List[Attribute] = newList()
  clinitAttrs.add(clinitCode)
  val clinitMethod = makeMethodInfo(ACC_STATIC, "<clinit>", "()V", clinitAttrs)

  // ── 3. Constructor <init>(params...)V ──────────────────────────────────────
  val ctorAsm = newAssembler(pool)
  emitAload(ctorAsm, 0)
  emitInvokespecial(ctorAsm, objCtorIdx)
  var slot = 1
  var qi = 0
  while qi < g.params.count {
    val p = g.params[qi]
    val fIdx = poolFieldref(pool, genClass, p.paramName, typeDescriptor(p.paramType))
    emitAload(ctorAsm, 0)
    emitFieldLoad(p.paramType, slot, ctorAsm)
    emitPutfield(ctorAsm, fIdx)
    match p.paramType {
      case JLong -> {
        slot = slot + 2
      }
      case JDouble -> {
        slot = slot + 2
      }
      case _ -> {
        slot = slot + 1
      }
    }
    qi = qi + 1
  }
  emitReturn(ctorAsm)
  val ctorMaxLocals = slot
  val ctorCode = assembleCode(ctorAsm, 2, ctorMaxLocals)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamTypes: List[JvmType] = newList()
  var ri = 0
  while ri < g.params.count {
    ctorParamTypes.add(g.params[ri].paramType)
    ri = ri + 1
  }
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParamTypes, JVoid), ctorAttrs)

  // ── 4. run()V — executes the generator body in a virtual thread ───────────
  // Body instructions with LYield replaced by SynchronousQueue.put(boxed_value).
  // Slot 0 = `this`; yieldTempSlot (one past the highest body slot) holds the
  // boxed value transiently.  Scan body insns first to find the max slot so
  // yieldTempSlot doesn't collide with any existing local.
  var bodyMaxSlot = 0
  var bsi = 0
  while bsi < g.bodyInsns.count {
    match g.bodyInsns[bsi] {
      case LIload(s) -> {
        if s + 1 > bodyMaxSlot {
          bodyMaxSlot = s + 1
        }
      }
      case LLload(s) -> {
        if s + 2 > bodyMaxSlot {
          bodyMaxSlot = s + 2
        }
      }
      case LFload(s) -> {
        if s + 1 > bodyMaxSlot {
          bodyMaxSlot = s + 1
        }
      }
      case LDload(s) -> {
        if s + 2 > bodyMaxSlot {
          bodyMaxSlot = s + 2
        }
      }
      case LAload(s) -> {
        if s + 1 > bodyMaxSlot {
          bodyMaxSlot = s + 1
        }
      }
      case LIstore(s) -> {
        if s + 1 > bodyMaxSlot {
          bodyMaxSlot = s + 1
        }
      }
      case LLstore(s) -> {
        if s + 2 > bodyMaxSlot {
          bodyMaxSlot = s + 2
        }
      }
      case LFstore(s) -> {
        if s + 1 > bodyMaxSlot {
          bodyMaxSlot = s + 1
        }
      }
      case LDstore(s) -> {
        if s + 2 > bodyMaxSlot {
          bodyMaxSlot = s + 2
        }
      }
      case LAstore(s) -> {
        if s + 1 > bodyMaxSlot {
          bodyMaxSlot = s + 1
        }
      }
      case _ -> ()
    }
    bsi = bsi + 1
  }
  val yieldTempSlot = bodyMaxSlot
  val bodyMaxLocals = yieldTempSlot + 1

  val sqPutIdx = poolMethodref(pool, sqClass, "put", "(Ljava/lang/Object;)V")
  val bodyAsm = newAssembler(pool)
  emitLabel(bodyAsm, "run_try_start")
  var bi = 0
  while bi < g.bodyInsns.count {
    val insn = g.bodyInsns[bi]
    match insn {
      case LYield -> {
        // Box primitive; store to temp slot; load this._channel; reload value; put.
        match g.elemType {
          case JInt -> lowerInsn(LBoxInt, bodyAsm)
          case JLong -> lowerInsn(LBoxLong, bodyAsm)
          case JFloat -> lowerInsn(LBoxFloat, bodyAsm)
          case JDouble -> lowerInsn(LBoxDouble, bodyAsm)
          case JBoolean -> lowerInsn(LBoxBool, bodyAsm)
          case JByte -> lowerInsn(LBoxByte, bodyAsm)
          case JChar -> lowerInsn(LBoxChar, bodyAsm)
          case JShort -> lowerInsn(LBoxShort, bodyAsm)
          case _ -> ()
        }
        emitAstore(bodyAsm, yieldTempSlot)
        emitAload(bodyAsm, 0)
        emitGetfield(bodyAsm, channelIdx)
        emitAload(bodyAsm, yieldTempSlot)
        emitInvokevirtual(bodyAsm, sqPutIdx)
      }
      case _ -> lowerInsn(insn, bodyAsm)
    }
    bi = bi + 1
  }
  // Normal-path sentinel put: body completed without throwing.
  emitLabel(bodyAsm, "run_body_end")
  emitAload(bodyAsm, 0)
  emitGetfield(bodyAsm, channelIdx)
  emitGetstatic(bodyAsm, sentinelIdx)
  emitLabel(bodyAsm, "run_sentinel1_start")
  emitInvokevirtual(bodyAsm, sqPutIdx)
  emitLabel(bodyAsm, "run_sentinel1_end")
  emitReturn(bodyAsm)
  // Catch-all handler: body (or a yield put) threw a non-IE exception.
  // Save the exception, put the sentinel so the consumer unblocks, then
  // rethrow.  The virtual thread's exception is discarded by the JVM (virtual
  // threads do not propagate uncaught exceptions to their starter), but
  // unblocking the consumer ensures hasNext() returns false rather than
  // deadlocking indefinitely in take().
  emitLabel(bodyAsm, "run_catch_all")
  emitAstore(bodyAsm, yieldTempSlot)
  emitAload(bodyAsm, 0)
  emitGetfield(bodyAsm, channelIdx)
  emitGetstatic(bodyAsm, sentinelIdx)
  emitLabel(bodyAsm, "run_sentinel2_start")
  emitInvokevirtual(bodyAsm, sqPutIdx)
  emitLabel(bodyAsm, "run_sentinel2_end")
  emitAload(bodyAsm, yieldTempSlot)
  emitAthrow(bodyAsm)
  // InterruptedException from either sentinel put: consumer abandoned iteration;
  // swallow and exit.  The thread's interrupted status is cleared by catching
  // IE, so a subsequent put (sentinel2 path) would not re-throw unless the
  // thread is interrupted again externally, which is outside Lyric's control.
  emitLabel(bodyAsm, "run_ie_handler")
  emitPop(bodyAsm)
  emitReturn(bodyAsm)
  val ieClassIdx = poolClass(pool, "java/lang/InterruptedException")
  // Handler 1: catch-all for the body (including yield puts) so the sentinel is
  //            always put before the producer exits.
  addExceptionHandler(bodyAsm, "run_try_start", "run_body_end", "run_catch_all", 0)
  // Handler 2: InterruptedException from the normal-path sentinel put (consumer gone).
  addExceptionHandler(bodyAsm, "run_sentinel1_start", "run_sentinel1_end", "run_ie_handler", ieClassIdx)
  // Handler 3: InterruptedException from the exception-path sentinel put (consumer gone
  //            while the producer was also handling another exception).
  addExceptionHandler(bodyAsm, "run_sentinel2_start", "run_sentinel2_end", "run_ie_handler", ieClassIdx)
  val runMaxStack = if bodyAsm.peakStack >= 3 then bodyAsm.peakStack else 3
  val bodyCode = assembleCode(bodyAsm, runMaxStack, bodyMaxLocals)
  val bodyAttrs: List[Attribute] = newList()
  bodyAttrs.add(bodyCode)
  val bodyPs: List[JvmType] = newList()
  val runMethod = makeMethodInfo(ACC_PUBLIC, "run", buildDescriptor(bodyPs, JVoid), bodyAttrs)

  // ── 5. iterator(): Iterator ────────────────────────────────────────────────
  // Initialise the channel, reset state, start a virtual thread running `this`
  // (which executes run()), and return this as Iterator.
  //
  // Resource-leak note (early-exit / re-entry):
  //   If the consumer stops calling hasNext() before the generator is exhausted
  //   (e.g. a `break` from a `for` loop), the producer virtual thread remains
  //   parked in SynchronousQueue.put() indefinitely — it holds no OS thread
  //   (virtual threads are cheap), but it IS a GC root until the generator object
  //   itself is collected.  Callers that truncate iteration must be aware of this
  //   cost; interrupt-on-abandon is a tracked follow-up (#3565).
  //
  //   Re-entry (calling iterator() while a prior iteration is in progress) replaces
  //   the channel, orphaning the running virtual thread permanently in put() with no
  //   recipient.  This constitutes a thread leak.  Callers must not re-enter
  //   iterator() during an active iteration.
  val iterAsm = newAssembler(pool)
  val startVtRef = poolMethodref(pool, threadClass, "startVirtualThread", "(Ljava/lang/Runnable;)Ljava/lang/Thread;")
  // _channel = new SynchronousQueue()
  emitAload(iterAsm, 0)
  emitNew(iterAsm, poolClass(pool, sqClass))
  emitDup(iterAsm)
  emitInvokespecial(iterAsm, sqCtorIdx)
  emitPutfield(iterAsm, channelIdx)
  // _done = false (0)
  emitAload(iterAsm, 0)
  emitIconst(iterAsm, 0)
  emitPutfield(iterAsm, doneIdx)
  // _pending = null
  emitAload(iterAsm, 0)
  emitAconstNull(iterAsm)
  emitPutfield(iterAsm, pendingIdx)
  // Thread.startVirtualThread(this) — discard the returned Thread
  emitAload(iterAsm, 0)
  emitInvokestatic(iterAsm, startVtRef)
  emitPop(iterAsm)
  // return this
  emitAload(iterAsm, 0)
  emitAreturn(iterAsm)
  val iterPs: List[JvmType] = newList()
  val iterRetType = JRef(className = iterClass)
  // maxStack=3: new + dup before invokespecial SynchronousQueue.<init>
  val iterCode = assembleCode(iterAsm, 3, 1)
  val iterAttrs: List[Attribute] = newList()
  iterAttrs.add(iterCode)
  val iterMethod = makeMethodInfo(ACC_PUBLIC, "iterator", buildDescriptor(iterPs, iterRetType), iterAttrs)

  // ── 6. hasNext(): boolean ──────────────────────────────────────────────────
  // slot 0 = this, slot 1 = the value taken from the channel (v)
  val hnAsm = newAssembler(pool)
  val sqTakeIdx = poolMethodref(pool, sqClass, "take", "()Ljava/lang/Object;")
  // if (_done) return false
  emitAload(hnAsm, 0)
  emitGetfield(hnAsm, doneIdx)
  emitIfeq(hnAsm, "hn_try_start")
  emitIconst(hnAsm, 0)
  emitIreturn(hnAsm)
  // try: v = _channel.take()
  emitLabel(hnAsm, "hn_try_start")
  emitAload(hnAsm, 0)
  emitGetfield(hnAsm, channelIdx)
  emitInvokevirtual(hnAsm, sqTakeIdx)
  emitAstore(hnAsm, 1)
  // if (v == _DONE_SENTINEL) { _done = true; return false; }
  emitAload(hnAsm, 1)
  emitGetstatic(hnAsm, sentinelIdx)
  emitIfAcmpne(hnAsm, "hn_pending")
  emitAload(hnAsm, 0)
  emitIconst(hnAsm, 1)
  emitPutfield(hnAsm, doneIdx)
  emitIconst(hnAsm, 0)
  emitIreturn(hnAsm)
  // _pending = v; return true
  emitLabel(hnAsm, "hn_pending")
  emitAload(hnAsm, 0)
  emitAload(hnAsm, 1)
  emitPutfield(hnAsm, pendingIdx)
  emitIconst(hnAsm, 1)
  emitIreturn(hnAsm)
  // End of try range (never reached from the paths above; marks the handler end).
  emitLabel(hnAsm, "hn_try_end")
  // InterruptedException handler: _done = true; return false
  emitLabel(hnAsm, "hn_ie_handler")
  emitPop(hnAsm)
  emitAload(hnAsm, 0)
  emitIconst(hnAsm, 1)
  emitPutfield(hnAsm, doneIdx)
  emitIconst(hnAsm, 0)
  emitIreturn(hnAsm)
  val hnPs: List[JvmType] = newList()
  val hnCode = assembleCodeWith1Handler(hnAsm, 2, 2, "hn_try_start", "hn_try_end", "hn_ie_handler", ieClassIdx)
  val hnAttrs: List[Attribute] = newList()
  hnAttrs.add(hnCode)
  val hasNextMethod = makeMethodInfo(ACC_PUBLIC, "hasNext", buildDescriptor(hnPs, JBoolean), hnAttrs)

  // ── 7. next(): Object ──────────────────────────────────────────────────────
  val nextAsm = newAssembler(pool)
  emitAload(nextAsm, 0)
  emitGetfield(nextAsm, pendingIdx)
  emitAreturn(nextAsm)
  val nextPs: List[JvmType] = newList()
  val nextCode = assembleCode(nextAsm, 1, 1)
  val nextAttrs: List[Attribute] = newList()
  nextAttrs.add(nextCode)
  val nextMethod = makeMethodInfo(ACC_PUBLIC, "next", buildDescriptor(nextPs, objType), nextAttrs)

  // ── 8. Assemble generator class ────────────────────────────────────────────
  val genMethods: List[MethodInfo] = newList()
  genMethods.add(clinitMethod)
  genMethods.add(ctorMethod)
  genMethods.add(runMethod)
  genMethods.add(iterMethod)
  genMethods.add(hasNextMethod)
  genMethods.add(nextMethod)
  val genIfaces: List[String] = newList()
  genIfaces.add(iterableClass)
  genIfaces.add(iterClass)
  genIfaces.add(runnableClass)
  // Use Java 5 (version 49) so the verifier does not require StackMapTable
  // for hasNext()'s branches and run()'s exception handler.
  result.add(
    ClassFile(
      minorVersion = 0,
      majorVersion = 49,
      flags = ACC_PUBLIC + ACC_SUPER,
      thisClass = genClass,
      superClass = "java/lang/Object",
      interfaces = genIfaces,
      fields = fieldsOut,
      methods = genMethods,
      attrs = newList()
    )
  )

  // ── 9. Kickoff method on host class ────────────────────────────────────────
  // When hostClass is empty the caller (codegenPackage full pipeline) has
  // arranged for a factory LFunc in LPFuncs; skip the separate host class.
  if g.hostClass != "" {
    val kickAsm = newAssembler(pool)
    val genCtorIdx = poolMethodref(pool, genClass, "<init>", buildDescriptor(ctorParamTypes, JVoid))
    val genClassIdx = poolClass(pool, genClass)
    emitNew(kickAsm, genClassIdx)
    emitDup(kickAsm)
    var ki = 0
    var kslot = 0
    // static method: params start at slot 0 (no `this`)
    while ki < g.params.count {
      emitFieldLoad(g.params[ki].paramType, kslot, kickAsm)
      match g.params[ki].paramType {
        case JLong -> {
          kslot = kslot + 2
        }
        case JDouble -> {
          kslot = kslot + 2
        }
        case _ -> {
          kslot = kslot + 1
        }
      }
      ki = ki + 1
    }
    emitInvokespecial(kickAsm, genCtorIdx)
    emitAreturn(kickAsm)
    val kickPs: List[JvmType] = newList()
    var kpi = 0
    while kpi < g.params.count {
      kickPs.add(g.params[kpi].paramType)
      kpi = kpi + 1
    }
    // maxLocals = kslot = number of param slots (0 when no params; static, no `this`).
    val kickCode = assembleCode(kickAsm, 4, kslot)
    val kickAttrs: List[Attribute] = newList()
    kickAttrs.add(kickCode)
    val kickMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, g.methodName, buildDescriptor(kickPs, objType), kickAttrs)
    val kickMethods: List[MethodInfo] = newList()
    kickMethods.add(kickMethod)
    result.add(makeClassWithMethods(g.hostClass, kickMethods))
  }
  result
}

// ── B120: lowerStructuredScope (StructuredTaskScope) ──────────────────────────
//
// `java.util.concurrent.StructuredTaskScope` changed shape across JDK previews:
//   • JDK 21..23 (JEP 453/462/480): a *class* opened via
//     `new StructuredTaskScope.ShutdownOnFailure()`, joined with `join()` and
//     subtask-state checked per subtask to propagate failure, all dispatched
//     with `invokevirtual`.  This is the form the emitter targets today
//     (Java 21 class-file version, major 65).
//   • JDK 24+   (JEP 499 onward):  a sealed *interface* opened via the static
//     factory `StructuredTaskScope.open()`, with `fork`/`join`/`close`
//     dispatched via `invokeinterface`.  `ShutdownOnFailure` no longer exists.
//
// The two encodings are mutually incompatible: emitting the interface form
// against a JDK-21 runtime throws `IncompatibleClassChangeError` (the JVM
// resolves `open()` as a class Methodref, not an InterfaceMethodref), and the
// `ShutdownOnFailure` class is absent on JDK 24+.  The JDK-24+ interface
// lowering is deferred until the toolchain can build/run on that JDK and the
// (still-preview, still-changing) method descriptors can be verified end-to-end
// rather than guessed — tracked in #2263.  Until then the lowering is gated on
// the detected runtime JDK: JDK 21..23 emits the verified `ShutdownOnFailure`
// form; JDK 24+ raises a clear, actionable compiler error instead of shipping
// untestable bytecode.
/// Emit bytecode to open a structured-concurrency scope, fork each callable
/// class (which must implement `Callable`), join, check every subtask for
/// failure (rethrowing the cause if any subtask failed), then close the scope.
/// Supported on JDK 21..23 (`StructuredTaskScope.ShutdownOnFailure`); JDK 24+
/// support is tracked in #2263.  The scope reference is stored in `scopeSlot`;
/// each forked task is stored in successive local slots starting at
/// `firstTaskSlot`.
pub func lowerScopeBlock(
  asm: in MethodAssembler,
  callableNames: in List[String],
  scopeSlot: in Int,
  firstTaskSlot: in Int,
): Unit {
  if detectJavaFeatureVersion() >= 24 {
    lowerScopeBlockJdk24(asm, callableNames, scopeSlot, firstTaskSlot)
  } else {
    lowerScopeBlockShutdownOnFailure(asm, callableNames, scopeSlot, firstTaskSlot)
  }
}

// JDK 21..23: StructuredTaskScope.ShutdownOnFailure (class API, invokevirtual).
func lowerScopeBlockShutdownOnFailure(
  asm: in MethodAssembler,
  callableNames: in List[String],
  scopeSlot: in Int,
  firstTaskSlot: in Int,
): Unit {
  val scopeClass = "java/util/concurrent/StructuredTaskScope$ShutdownOnFailure"

  // new ShutdownOnFailure(); store to scopeSlot
  emitNew(asm, poolClass(asm.pool, scopeClass))
  emitDup(asm)
  emitInvokespecial(asm, poolMethodref(asm.pool, scopeClass, "<init>", "()V"))
  emitAstore(asm, scopeSlot)

  // fork each callable — invokevirtual on ShutdownOnFailure (class API, not interface)
  val forkDesc = "(Ljava/util/concurrent/Callable;)Ljava/util/concurrent/StructuredTaskScope$Subtask;"
  var taskSlot = firstTaskSlot
  for callableName in callableNames.toArray() {
    val callableClass = poolClass(asm.pool, callableName)
    val callableCtor = poolMethodref(asm.pool, callableName, "<init>", "()V")
    val forkRef = poolMethodref(asm.pool, scopeClass, "fork", forkDesc)

    emitAload(asm, scopeSlot)
    emitNew(asm, callableClass)
    emitDup(asm)
    emitInvokespecial(asm, callableCtor)
    emitInvokevirtual(asm, forkRef)
    emitAstore(asm, taskSlot)
    taskSlot = taskSlot + 1
  }

  // join() — blocks until all forked subtasks finish; returns this scope (discarded)
  val joinRef = poolMethodref(
    asm.pool,
    scopeClass,
    "join",
    "()Ljava/util/concurrent/StructuredTaskScope$ShutdownOnFailure;"
  )
  val closeRef = poolMethodref(asm.pool, scopeClass, "close", "()V")
  emitAload(asm, scopeSlot)
  emitInvokevirtual(asm, joinRef)
  emitPop(asm)

  // Check each subtask: if state() == FAILED, rethrow its exception.
  // Subtask is a sealed interface in JDK 21+, so state() and exception() use invokeinterface.
  val subtaskIface = "java/util/concurrent/StructuredTaskScope$Subtask"
  val stateClass = "java/util/concurrent/StructuredTaskScope$Subtask$State"
  val stateDesc = "Ljava/util/concurrent/StructuredTaskScope$Subtask$State;"
  val stateRef = poolIfaceMethodref(asm.pool, subtaskIface, "state", "()" + stateDesc)
  val excRef = poolIfaceMethodref(asm.pool, subtaskIface, "exception", "()Ljava/lang/Throwable;")
  val failedRef = poolFieldref(asm.pool, stateClass, "FAILED", stateDesc)
  var checkSlot = firstTaskSlot
  var checkIdx = 0
  while checkIdx < callableNames.count {
    val skipLabel = "scope_skip_" + toString(scopeSlot) + "_" + toString(checkSlot)
    emitAload(asm, checkSlot)
    emitInvokeinterface(asm, stateRef, 1)
    emitGetstatic(asm, failedRef)
    emitIfAcmpne(asm, skipLabel)
    // close() before rethrow so the scope is not leaked on the failure path.
    // join() has already returned so all subtasks are settled; it is safe to
    // close here before inspecting exception().
    // Known limitation: if close() itself throws (e.g. InterruptedException),
    // it will replace the subtask's exception.  A try-finally exception-handler
    // pattern would avoid this but is deferred with #2263 (JDK 24+ scope work).
    emitAload(asm, scopeSlot)
    emitInvokevirtual(asm, closeRef)
    emitAload(asm, checkSlot)
    emitInvokeinterface(asm, excRef, 1)
    emitAthrow(asm)
    emitLabel(asm, skipLabel)
    checkSlot = checkSlot + 1
    checkIdx = checkIdx + 1
  }

  // close() on the success path — all subtasks succeeded.
  emitAload(asm, scopeSlot)
  emitInvokevirtual(asm, closeRef)
}

// JDK 24+: StructuredTaskScope sealed interface (JEP 499), invokeinterface.
// The default open() scope makes join() throw FailedException (a RuntimeException
// subtype) if any subtask failed, so explicit per-subtask state checks are not
// needed — failure propagates automatically.
// `firstTaskSlot` is accepted for signature parity with
// `lowerScopeBlockShutdownOnFailure` (which stores per-subtask results in
// successive slots).  On the JDK 24 path, fork() results are discarded via
// emitPop (FailedException from join() propagates failure automatically); the
// slot IS used by the catch handler to temporarily save the Throwable across
// the close() call so it can be rethrown.
func lowerScopeBlockJdk24(
  asm: in MethodAssembler,
  callableNames: in List[String],
  scopeSlot: in Int,
  firstTaskSlot: in Int,
): Unit {
  val scopeIface = "java/util/concurrent/StructuredTaskScope"

  // StructuredTaskScope.open() — static factory on the interface; invokestatic
  // with an InterfaceMethodref entry is valid at class-file version 52+ (Java 8+).
  val openRef = poolIfaceMethodref(asm.pool, scopeIface, "open", "()Ljava/util/concurrent/StructuredTaskScope;")
  emitInvokestatic(asm, openRef)
  emitAstore(asm, scopeSlot)

  // fork each callable — invokeinterface on StructuredTaskScope (interface API).
  // The Subtask return value is discarded; failure propagates via FailedException
  // from join(), so there is no per-subtask result slot needed.
  val forkDesc = "(Ljava/util/concurrent/Callable;)Ljava/util/concurrent/StructuredTaskScope$Subtask;"
  for callableName in callableNames.toArray() {
    val callableClass = poolClass(asm.pool, callableName)
    val callableCtor = poolMethodref(asm.pool, callableName, "<init>", "()V")
    val forkRef = poolIfaceMethodref(asm.pool, scopeIface, "fork", forkDesc)
    emitAload(asm, scopeSlot)
    emitNew(asm, callableClass)
    emitDup(asm)
    emitInvokespecial(asm, callableCtor)
    emitInvokeinterface(asm, forkRef, 2)
    emitPop(asm)
  }

  // join() wrapped in a try-finally so close() always runs, even when join()
  // throws FailedException (a RuntimeException) because a subtask failed.
  //
  // Emitted shape (class-file version 49, no StackMapTable needed):
  //
  //   [join_start]
  //     aload scopeSlot
  //     invokeinterface join
  //     pop                    // discard the scope return value on success
  //   [join_end / close_start]
  //     aload scopeSlot
  //     invokeinterface close
  //     goto done
  //   [exn_handler]            <- exception table entry: [join_start, close_start) → exn_handler, catch-all
  //     pop                    // discard the Throwable on the handler stack
  //     aload scopeSlot
  //     invokeinterface close
  //     athrow                 // rethrow FailedException (or any other Throwable)
  //   [done]

  val joinRef = poolIfaceMethodref(asm.pool, scopeIface, "join", "()Ljava/util/concurrent/StructuredTaskScope;")
  val closeRef = poolIfaceMethodref(asm.pool, scopeIface, "close", "()V")

  val joinStart = "scope24_join_start_" + toString(scopeSlot)
  val closeStart = "scope24_close_start_" + toString(scopeSlot)
  val exnHandler = "scope24_exn_" + toString(scopeSlot)
  val done = "scope24_done_" + toString(scopeSlot)

  emitLabel(asm, joinStart)
  emitAload(asm, scopeSlot)
  emitInvokeinterface(asm, joinRef, 1)
  emitPop(asm)
  emitLabel(asm, closeStart)
  emitAload(asm, scopeSlot)
  emitInvokeinterface(asm, closeRef, 1)
  emitGoto(asm, done)
  emitLabel(asm, exnHandler)
  // Stack on handler entry: [Throwable].  Save it so close() can run and we can rethrow.
  emitAstore(asm, firstTaskSlot)
  emitAload(asm, scopeSlot)
  emitInvokeinterface(asm, closeRef, 1)
  emitAload(asm, firstTaskSlot)
  emitAthrow(asm)
  emitLabel(asm, done)

  // Register a catch-all (catchType=0) handler so close() is always reached.
  addExceptionHandler(asm, joinStart, closeStart, exnHandler, 0)
}

// ── JDK feature-version detection ─────────────────────────────────────────────
//
// Reads `$JAVA_HOME/release` (`JAVA_VERSION="21.0.10"` → 21) so the scope
// lowering targets the API the runtime actually provides.  Anchored solely to
// `JAVA_HOME` — the variable that pins the active JDK in CI and production
// builds — rather than scanning `/usr/lib/jvm`, whose directory order is
// filesystem-dependent and could non-deterministically pick the wrong JDK on a
// multi-JDK machine (#2259).  When `JAVA_HOME` is unset or its `release` file
// is missing / unparseable, falls back to spawning `java --version` and parsing
// its stdout, so the guard fires correctly even when `JAVA_HOME` is absent
// (e.g. most macOS developer setups).  `java --version` (double-dash, Java 9+)
// writes the version to stdout, not stderr, so `ProcessCapture.runCapture`
// captures it as a plain String.  Ultimate fallback is 21 — safe because the
// only supported lowering today is the JDK 21..23 `ShutdownOnFailure` form, so
// we'd rather panic with a clear message than silently generate broken bytecode
// for an undetected JDK 24+.
pub func detectJavaFeatureVersion(): Int {
  val javaHome = Env.getVarOrDefault("JAVA_HOME", "")
  if javaHome.length > 0 {
    match File.readText(javaHome + "/release") {
      case Ok(text) -> return parseJavaFeatureVersion(text)
      case Err(_) -> ()
    }
  }
  // Fallback: spawn `java --version` and parse stdout.
  // Format: `java 25.0.3 ...` or `openjdk 21.0.1 ...` (second token is version).
  // Pass the result directly to avoid `SLocal` type-erasure issues in the F#
  // bootstrap emitter when binding cross-package function results to `val`.
  // The `List[String]` return type on javaVersionArgs() is required so the
  // F# bootstrap emitter emits `List<string>`-typed IL rather than
  // `List<object>` (#867 / generator.l pattern).
  parseJavaVersionFromOutput(ProcessCapture.runCapture("java", javaVersionArgs(), ""))
}

// Returns the `["--version"]` args list.  The explicit `List[String]` return
// type is required so the F# bootstrap emitter emits `List<string>`-typed IL
// rather than `List<object>`, which would cause a CLR JIT rejection (#867).
func javaVersionArgs(): List[String] {
  val args: List[String] = newList()
  args.add("--version")
  args
}

// Extract the leading integer of the JDK feature version from a `release`
// file's `JAVA_VERSION="X.Y.Z"` line (e.g. `21.0.10` → 21, `24` → 24).
// Returns 21 when the marker is absent or unparseable.
func parseJavaFeatureVersion(text: in String): Int {
  val marker = "JAVA_VERSION=\""
  val idx = text.indexOf(marker)
  if idx < 0 {
    return 21
  }
  var i = idx + marker.length
  var n = 0
  var sawDigit = false
  var done = false
  while i < text.length and not done {
    val d = asciiDigit(text[i])
    if d < 0 {
      done = true
    } else {
      n = n * 10 + d
      sawDigit = true
      i = i + 1
    }
  }
  if sawDigit {
    n
  } else {
    21
  }
}

// Parse the JDK major feature version from `java --version` stdout output.
// Input looks like: `java 25.0.3 2026-04-21 ...` or `openjdk 21.0.1 ...`
// (The second whitespace-delimited token is the version string.)
// Returns 21 on parse failure (safe fallback — see detectJavaFeatureVersion).
func parseJavaVersionFromOutput(output: in String): Int {
  var i = 0
  val len = output.length
  // Skip the first token (e.g. "java" or "openjdk")
  while i < len and output[i] != ' ' {
    i = i + 1
  }
  // Skip whitespace between tokens
  while i < len and output[i] == ' ' {
    i = i + 1
  }
  // Parse the leading decimal integer of the version string
  var n = 0
  var sawDigit = false
  var done = false
  while i < len and not done {
    val d = asciiDigit(output[i])
    if d < 0 {
      done = true
    } else {
      n = n * 10 + d
      sawDigit = true
      i = i + 1
    }
  }
  if sawDigit {
    n
  } else {
    21
  }
}

// ASCII digit value (0..9) or -1 for a non-digit char.
func asciiDigit(c: in Char): Int {
  match c {
    case '0' -> 0
    case '1' -> 1
    case '2' -> 2
    case '3' -> 3
    case '4' -> 4
    case '5' -> 5
    case '6' -> 6
    case '7' -> 7
    case '8' -> 8
    case '9' -> 9
    case _ -> -1
  }
}

// ── B121: lowerFuncWithContract (inline requires/ensures bytecode) ────────────
pub record LContract {
  requiresInsns: List[LInsn]
  // pushes Bool (1=ok, 0=violated); evaluated at entry
  ensuresInsns: List[LInsn]
  // same, evaluated before return
}

/// Like lowerFunc but splices contract guard bytecode around the body:
///   1. Evaluate requiresInsns; throw AssertionError if result is 0.
///   2. Execute the body.
///   3. Evaluate ensuresInsns; throw AssertionError if result is 0.
///   4. Return.
pub func lowerFuncWithContract(f: in LFunc, contract: in LContract, pool: in Pool): MethodInfo {
  val assertErrClass = "java/lang/AssertionError"
  val assertPs: List[JvmType] = newList()

  val wInsns: List[LInsn] = newList()

  // requires check
  var ri = 0
  while ri < contract.requiresInsns.count {
    wInsns.add(contract.requiresInsns[ri])
    ri = ri + 1
  }
  wInsns.add(LIfne(label = "req_ok"))
  wInsns.add(LNew(className = assertErrClass))
  wInsns.add(LDup)
  wInsns.add(LPushString(s = "requires violated"))
  val aePsList: List[JvmType] = newList()
  aePsList.add(JRef(className = "java/lang/Object"))
  wInsns.add(LInvokespecial(owner = assertErrClass, name = "<init>", params = aePsList, ret = JVoid))
  wInsns.add(LAthrow)
  wInsns.add(LLabel(name = "req_ok"))

  // Body
  var bi = 0
  while bi < f.insns.count {
    wInsns.add(f.insns[bi])
    bi = bi + 1
  }

  // Save result before ensures check (only needed when ensures is non-empty)
  val hasEnsures = contract.ensuresInsns.count > 0
  val resultSlot = f.maxLocals
  if hasEnsures and fieldSlotSize(f.ret) > 0 {
    wInsns.add(storeInsn(f.ret, resultSlot))
  }

  // ensures check
  if hasEnsures {
    var ei = 0
    while ei < contract.ensuresInsns.count {
      wInsns.add(contract.ensuresInsns[ei])
      ei = ei + 1
    }
    wInsns.add(LIfne(label = "ens_ok"))
    wInsns.add(LNew(className = assertErrClass))
    wInsns.add(LDup)
    wInsns.add(LPushString(s = "ensures violated"))
    wInsns.add(LInvokespecial(owner = assertErrClass, name = "<init>", params = aePsList, ret = JVoid))
    wInsns.add(LAthrow)
    wInsns.add(LLabel(name = "ens_ok"))
  }

  // Return (reload result from slot only when ensures was active and saved it)
  if hasEnsures and fieldSlotSize(f.ret) > 0 {
    wInsns.add(loadInsn(f.ret, resultSlot))
  }
  wInsns.add(returnInsn(f.ret))

  val extraLocals = if hasEnsures then fieldSlotSize(f.ret) else 0
  val wFunc = LFunc(
    flags = f.flags,
    name = f.name,
    params = f.params,
    ret = f.ret,
    insns = wInsns,
    maxStack = f.maxStack + 4,
    // +4 for new AssertionError + dup + ldc + invokespecial
    maxLocals = f.maxLocals + extraLocals
  )
  lowerFunc(wFunc, pool)
}

// ── B122: lowerDeriveEquality (@derive(Equals) + @derive(Hash)) ──────────────
pub record LRecordWithDerives {
  className: String
  fields: List[LField]
  deriveEq: Bool
  deriveHash: Bool
}

// `equals(Object): boolean` with field-by-field comparison, as a plain
// `LFunc` — reusable both by `lowerDeriveEquality` below (the standalone
// B122 self-test path) and by `Jvm.Codegen`'s real record-lowering pipeline
// for `@derive(Equals)` records (docs/44 m-key, #4982 Finding 1).
pub func buildDeriveEqualsFunc(className: in String, fields: in List[LField]): LFunc {
  val eqInsns: List[LInsn] = newList()

  // Pre-initialize slot 2 (the cast result) so StackMapTable frames at early
  // branch targets (before slot 2 is assigned) declare it as live.
  eqInsns.add(LAconstNull)
  eqInsns.add(LAstoreAs(slot = 2, className = className))

  // if (this == other) return true
  eqInsns.add(LAload(slot = 0))
  eqInsns.add(LAload(slot = 1))
  eqInsns.add(LIfAcmpeq(label = "eq_same"))
  eqInsns.add(LGoto(label = "eq_check_type"))
  eqInsns.add(LLabel(name = "eq_same"))
  eqInsns.add(LIconst(v = 1))
  eqInsns.add(LIreturn)
  eqInsns.add(LLabel(name = "eq_check_type"))

  // if (!(other instanceof <className>)) return false
  eqInsns.add(LAload(slot = 1))
  eqInsns.add(LInstanceof(className = className))
  eqInsns.add(LIfne(label = "eq_cast"))
  eqInsns.add(LIconst(v = 0))
  eqInsns.add(LIreturn)
  eqInsns.add(LLabel(name = "eq_cast"))

  // <className> o = (<className>) other; stored in slot 2
  eqInsns.add(LAload(slot = 1))
  eqInsns.add(LCheckcast(className = className))
  eqInsns.add(LAstoreAs(slot = 2, className = className))

  // Compare each field; return false on mismatch
  for fld in fields.toArray() {
    val skipLabel = "eq_skip_" + fld.name
    eqInsns.add(LAload(slot = 0))
    eqInsns.add(LGetfield(owner = className, name = fld.name, t = fld.fieldType))
    eqInsns.add(LAload(slot = 2))
    eqInsns.add(LGetfield(owner = className, name = fld.name, t = fld.fieldType))
    match fld.fieldType {
      case JInt -> eqInsns.add(LIfIcmpeq(label = skipLabel))
      case JBoolean -> eqInsns.add(LIfIcmpeq(label = skipLabel))
      case JByte -> eqInsns.add(LIfIcmpeq(label = skipLabel))
      case JChar -> eqInsns.add(LIfIcmpeq(label = skipLabel))
      case JShort -> eqInsns.add(LIfIcmpeq(label = skipLabel))
      case JLong -> {
        // `LIfIcmpeq`/`LIfAcmpeq` both operate on single-slot values; a `long`
        // is a two-slot primitive and neither opcode applies (#4993).
        eqInsns.add(LLcmp)
        eqInsns.add(LIfeq(label = skipLabel))
      }
      case JDouble -> {
        // Two-slot primitive, same hazard as `JLong`.  The "l" (NaN → -1)
        // variant matches `==`'s IEEE-754 semantics (mirrors `lowerCmp`).
        eqInsns.add(LDcmpl)
        eqInsns.add(LIfeq(label = skipLabel))
      }
      case JFloat -> {
        // Single-slot but NOT reference-typed; `LIfAcmpeq` expects two
        // references on the stack and would `VerifyError` on a raw `float`.
        eqInsns.add(LFcmpl)
        eqInsns.add(LIfeq(label = skipLabel))
      }
      case _ -> eqInsns.add(LIfAcmpeq(label = skipLabel))
    }
    eqInsns.add(LIconst(v = 0))
    eqInsns.add(LIreturn)
    eqInsns.add(LLabel(name = skipLabel))
  }
  eqInsns.add(LIconst(v = 1))
  eqInsns.add(LIreturn)

  val eqPs: List[JvmType] = newList()
  eqPs.add(JRef(className = "java/lang/Object"))
  LFunc(
    flags = ACC_PUBLIC,
    name = "equals",
    params = eqPs,
    ret = JBoolean,
    insns = eqInsns,
    maxStack = 4,
    maxLocals = 3
  )
}

// `hashCode(): int` — hash = 31 * hash + field_hash for each field, as a
// plain `LFunc` (reference fields dispatch to `Object.hashCode()`).  Reused
// the same way as `buildDeriveEqualsFunc` above.
pub func buildDeriveHashCodeFunc(className: in String, fields: in List[LField]): LFunc {
  val hashInsns: List[LInsn] = newList()
  hashInsns.add(LIconst(v = 1))
  // hash = 1
  hashInsns.add(LIstore(slot = 1))

  for fld in fields.toArray() {
    hashInsns.add(LIconst(v = 31))
    hashInsns.add(LIload(slot = 1))
    hashInsns.add(LImul)
    hashInsns.add(LAload(slot = 0))
    hashInsns.add(LGetfield(owner = className, name = fld.name, t = fld.fieldType))
    match fld.fieldType {
      case JInt -> ()
      case JBoolean -> ()
      case JByte -> ()
      case JChar -> ()
      case JShort -> ()
      case JLong -> {
        // `Object.hashCode()` requires a reference receiver; a raw `long` on
        // the stack would `VerifyError` (#4993).  `Long.hashCode(long): int`
        // (JDK 8+) computes the hash without boxing.
        val hcPs: List[JvmType] = newList()
        hcPs.add(JLong)
        hashInsns.add(LInvokestatic(owner = "java/lang/Long", name = "hashCode", params = hcPs, ret = JInt))
      }
      case JDouble -> {
        val hcPs: List[JvmType] = newList()
        hcPs.add(JDouble)
        hashInsns.add(LInvokestatic(owner = "java/lang/Double", name = "hashCode", params = hcPs, ret = JInt))
      }
      case JFloat -> {
        val hcPs: List[JvmType] = newList()
        hcPs.add(JFloat)
        hashInsns.add(LInvokestatic(owner = "java/lang/Float", name = "hashCode", params = hcPs, ret = JInt))
      }
      case _ -> {
        // For reference fields, call .hashCode()
        val hcPs: List[JvmType] = newList()
        hashInsns.add(LInvokevirtual(owner = "java/lang/Object", name = "hashCode", params = hcPs, ret = JInt))
      }
    }
    hashInsns.add(LIadd)
    hashInsns.add(LIstore(slot = 1))
  }
  hashInsns.add(LIload(slot = 1))
  hashInsns.add(LIreturn)

  val hashPs: List[JvmType] = newList()
  LFunc(
    flags = ACC_PUBLIC,
    name = "hashCode",
    params = hashPs,
    ret = JInt,
    insns = hashInsns,
    maxStack = 4,
    maxLocals = 2
  )
}

/// Lower a record with `@derive(Equals)` and/or `@derive(Hash)`.
/// Emits `equals(Object): boolean` with field-by-field comparison
/// and `hashCode(): int` with a prime-multiply accumulator.
pub func lowerDeriveEquality(d: in LRecordWithDerives, pool: in Pool): ClassFile {
  // First build the base record
  val r = LRecord(className = d.className, fields = d.fields, methods = newList(), implementsIfaces = newList())
  val cf = lowerRecord(r, pool)

  val extraMethods: List[MethodInfo] = newList()

  if d.deriveEq {
    extraMethods.add(lowerFuncForClass(buildDeriveEqualsFunc(d.className, d.fields), d.className, pool))
  }

  if d.deriveHash {
    extraMethods.add(lowerFuncForClass(buildDeriveHashCodeFunc(d.className, d.fields), d.className, pool))
  }

  // Rebuild ClassFile with the extra methods appended
  val allMethods: List[MethodInfo] = newList()
  for m in cf.methods.toArray() {
    allMethods.add(m)
  }
  for m in extraMethods.toArray() {
    allMethods.add(m)
  }
  ClassFile(
    minorVersion = cf.minorVersion,
    majorVersion = cf.majorVersion,
    flags = cf.flags,
    thisClass = cf.thisClass,
    superClass = cf.superClass,
    interfaces = cf.interfaces,
    fields = cf.fields,
    methods = allMethods,
    attrs = cf.attrs
  )
}

// ── B123: lowerDeriveOrd (@generate(Compare/Add/Sub) on distinct types) ─────────
pub record LDistinctWithDerives {
  wrapperClass: String
  underlyingType: JvmType
  deriveCompare: Bool
  deriveAdd: Bool
  deriveSub: Bool
}

/// Lower a distinct type with optional @generate(Compare), @generate(Add), @generate(Sub).
/// Emits `compareTo(T): int`, `$add(T): T`, `$sub(T): T` by delegating to the
/// underlying primitive.
pub func lowerDeriveOrd(d: in LDistinctWithDerives, pool: in Pool): ClassFile {
  // Build base distinct type
  val base = LDistinctType(wrapperClass = d.wrapperClass, underlyingType = d.underlyingType)
  val cf = lowerDistinctType(base, pool)

  val extraMethods: List[MethodInfo] = newList()
  val selfParam: List[JvmType] = newList()
  selfParam.add(JRef(className = d.wrapperClass))

  if d.deriveCompare {
    // compareTo(T other): int — compare underlying values
    val cmpAsm = newAssembler(pool)
    lowerInsn(LAload(slot = 0), cmpAsm)
    lowerInsn(LGetfield(owner = d.wrapperClass, name = "$value", t = d.underlyingType), cmpAsm)
    lowerInsn(LAload(slot = 1), cmpAsm)
    lowerInsn(LGetfield(owner = d.wrapperClass, name = "$value", t = d.underlyingType), cmpAsm)
    // For Long: lcmp; for Int: subtract
    match d.underlyingType {
      case JLong -> {
        lowerInsn(LLcmp, cmpAsm)
      }
      case _ -> {
        lowerInsn(LIsub, cmpAsm)
      }
    }
    lowerInsn(LIreturn, cmpAsm)
    val cmpCode = assembleCode(cmpAsm, 4, 2)
    val cmpAttrs: List[Attribute] = newList()
    cmpAttrs.add(cmpCode)
    extraMethods.add(makeMethodInfo(ACC_PUBLIC, "compareTo", buildDescriptor(selfParam, JInt), cmpAttrs))
  }

  if d.deriveAdd {
    // $add(T other): T — add underlying values, wrap in new T
    val addAsm = newAssembler(pool)
    lowerInsn(LNew(className = d.wrapperClass), addAsm)
    lowerInsn(LDup, addAsm)
    lowerInsn(LAload(slot = 0), addAsm)
    lowerInsn(LGetfield(owner = d.wrapperClass, name = "$value", t = d.underlyingType), addAsm)
    lowerInsn(LAload(slot = 1), addAsm)
    lowerInsn(LGetfield(owner = d.wrapperClass, name = "$value", t = d.underlyingType), addAsm)
    match d.underlyingType {
      case JLong -> lowerInsn(LLadd, addAsm)
      case _ -> lowerInsn(LIadd, addAsm)
    }
    val wrapperPs: List[JvmType] = newList()
    wrapperPs.add(d.underlyingType)
    lowerInsn(LInvokespecial(owner = d.wrapperClass, name = "<init>", params = wrapperPs, ret = JVoid), addAsm)
    lowerInsn(LAreturn, addAsm)
    val addCode = assembleCode(addAsm, 6, 2)
    val addAttrs: List[Attribute] = newList()
    addAttrs.add(addCode)
    extraMethods.add(
      makeMethodInfo(ACC_PUBLIC, "$add", buildDescriptor(selfParam, JRef(className = d.wrapperClass)), addAttrs)
    )
  }

  if d.deriveSub {
    // $sub(T other): T — subtract underlying values
    val subAsm = newAssembler(pool)
    lowerInsn(LNew(className = d.wrapperClass), subAsm)
    lowerInsn(LDup, subAsm)
    lowerInsn(LAload(slot = 0), subAsm)
    lowerInsn(LGetfield(owner = d.wrapperClass, name = "$value", t = d.underlyingType), subAsm)
    lowerInsn(LAload(slot = 1), subAsm)
    lowerInsn(LGetfield(owner = d.wrapperClass, name = "$value", t = d.underlyingType), subAsm)
    match d.underlyingType {
      case JLong -> lowerInsn(LLsub, subAsm)
      case _ -> lowerInsn(LIsub, subAsm)
    }
    val wrapperPsSub: List[JvmType] = newList()
    wrapperPsSub.add(d.underlyingType)
    lowerInsn(LInvokespecial(owner = d.wrapperClass, name = "<init>", params = wrapperPsSub, ret = JVoid), subAsm)
    lowerInsn(LAreturn, subAsm)
    val subCode = assembleCode(subAsm, 6, 2)
    val subAttrs: List[Attribute] = newList()
    subAttrs.add(subCode)
    extraMethods.add(
      makeMethodInfo(ACC_PUBLIC, "$sub", buildDescriptor(selfParam, JRef(className = d.wrapperClass)), subAttrs)
    )
  }

  // Rebuild ClassFile with extra methods
  val allMethods: List[MethodInfo] = newList()
  for m in cf.methods.toArray() {
    allMethods.add(m)
  }
  for m in extraMethods.toArray() {
    allMethods.add(m)
  }
  ClassFile(
    minorVersion = cf.minorVersion,
    majorVersion = cf.majorVersion,
    flags = cf.flags,
    thisClass = cf.thisClass,
    superClass = cf.superClass,
    interfaces = cf.interfaces,
    fields = cf.fields,
    methods = allMethods,
    attrs = cf.attrs
  )
}

// ── B124: lowerPackage (top-level integration entry point) ────────────────────
// A module-level `val NAME = expr`, emitted as a `public static final` field on
// the package host class and initialised in its `<clinit>`.  `initInsns` push
// the value (no store / return); `lowerFuncsToClass` emits the `putstatic` and
// the `<clinit>` wrapper.
pub record LStaticVal {
  name: String
  valType: JvmType
  initInsns: List[LInsn]
}

pub union LPackageItem {
  case LPRecord(rec: LRecord)
  case LPSealedUnion(su: LSealedUnion)
  case LPEnum(en: LEnumType)
  case LPOpaqueType(ot: LOpaqueType)
  // #3044: full-feature `@projectable` opaque (view twin + toView() +
  // optional tryInto(), with @hidden / @projectionBoundary / nesting).
  case LPProjectable(pt: LProjectableType)
  case LPDistinctType(dt: LDistinctType)
  case LPRangeType(rt: LRangeType)
  case LPExposedRecord(er: LExposedRecord)
  case LPProtected(pt: LProtected)
  // J3 M-3: `wire { … }` block — final DI factory class (private static fields,
  // private ctor, `bootstrap()V`, exposed-binding accessors).
  case LPWire(w: LWire)
  case LPFuncs(funcsClass: String, fns: List[LFunc], staticVals: List[LStaticVal])
  // B129/B130: async generator function (yield in async func body).
  // Covers Gap-4 (yield only) and Gap-4a (yield + await, bootstrap-synchronous).
  case LPAsyncGenerator(g: LGenFunc)
  // B126: a @test_module file compiled for the JVM target.
  // `className` is the JVM binary name (e.g. "math_tests").
  // `slots` carries per-test metadata; method bodies are stubs until B127+.
  case LPTestModule(className: String, slots: List[TestMethodSlot])
  // B132+: Lyric `interface` declaration — emits a JVM interface ClassFile.
  case LPInterface(iface: LInterface)
  // J2b closures (#2665): a synthesised lambda closure inner class.  Lowered via
  // `lowerClosure`, which emits the capture-field ctor + the functional-interface
  // method.  Drained from `FuncCtx.closureAcc` by `codegenPackageWithSigs`.
  case LPClosureClass(c: LClosure)
}

pub record LPackage {
  packageName: String
  items: List[LPackageItem]
}

func lowerFuncsToClass(
  funcsClass: in String, fns: in List[LFunc], staticVals: in List[LStaticVal], pool: in Pool
): ClassFile {
  val methods: List[MethodInfo] = newList()
  for fn in fns.toArray() {
    methods.add(lowerFunc(fn, pool))
  }

  // m-2: module-level `val NAME = expr` → `public static final` field on the
  // host class, initialised in a synthesised `<clinit>`.  The `<clinit>` is
  // built as an ordinary `<clinit>` LFunc and lowered through `lowerFunc` so it
  // reuses the same StackMapTable / max-stack machinery as user methods, which
  // keeps branchy initialisers (an init expression containing `if` / `match`)
  // verifiable.  Mirrors the MSIL `.cctor` static-field path.
  val cfFields: List[FieldInfo] = newList()
  if staticVals.count > 0 {
    val clinitInsns: List[LInsn] = newList()
    for sv in staticVals.toArray() {
      val fa: List[Attribute] = newList()
      cfFields.add(makeFieldInfo(ACC_PUBLIC + ACC_STATIC + ACC_FINAL, sv.name, typeDescriptor(sv.valType), fa))
      for insn in sv.initInsns.toArray() {
        clinitInsns.add(insn)
      }
      clinitInsns.add(LPutstatic(owner = funcsClass, name = sv.name, t = sv.valType))
    }
    clinitInsns.add(LReturn)
    val clinitParams: List[JvmType] = newList()
    val clinit = LFunc(
      flags = ACC_STATIC,
      name = "<clinit>",
      params = clinitParams,
      ret = JVoid,
      insns = clinitInsns,
      maxStack = 0,
      // 0 → lowerFuncImpl infers peak stack
      maxLocals = 0
    )
    methods.add(lowerFunc(clinit, pool))
  }

  if cfFields.count > 0 {
    makeClassFull(funcsClass, cfFields, methods)
  } else {
    makeClassWithMethods(funcsClass, methods)
  }
}

/// Dispatch over all package items and return the complete list of ClassFiles.
/// LPFuncs items are collected into a single `<funcsClass>` host class.
pub func lowerPackage(pkg: in LPackage, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()

  for item in pkg.items.toArray() {
    match item {
      case LPRecord(rec) -> {
        result.add(lowerRecord(rec, pool))
      }
      case LPSealedUnion(su) -> {
        val cfs = lowerSealedUnion(su, pool)
        for cf in cfs.toArray() {
          result.add(cf)
        }
      }
      case LPEnum(en) -> {
        result.add(lowerEnum(en, pool))
      }
      case LPOpaqueType(ot) -> {
        result.add(lowerOpaqueType(ot, pool))
        result.add(lowerOpaqueFacade(ot, pool))
      }
      case LPProjectable(pt) -> {
        val pcfs = lowerProjectableType(pt, pool)
        for cf in pcfs.toArray() {
          result.add(cf)
        }
        // Java-interop facade over the opaque, mirroring the plain-opaque arm.
        val pfFields: List[LOpaqueField] = newList()
        for f in pt.fields.toArray() {
          pfFields.add(LOpaqueField(name = f.name, fieldType = f.fieldType))
        }
        result.add(lowerOpaqueFacade(LOpaqueType(className = pt.opaqueClassName, fields = pfFields), pool))
      }
      case LPDistinctType(dt) -> {
        result.add(lowerDistinctType(dt, pool))
      }
      case LPRangeType(rt) -> {
        result.add(lowerRangeType(rt, pool))
      }
      case LPExposedRecord(er) -> {
        result.add(lowerExposedRecord(er, pool))
      }
      case LPProtected(pt) -> {
        result.add(lowerProtected(pt, pool))
      }
      case LPWire(w) -> {
        result.add(lowerWire(w, pool))
      }
      case LPFuncs(funcsClass, fns, staticVals) -> {
        result.add(lowerFuncsToClass(funcsClass, fns, staticVals, pool))
      }
      case LPAsyncGenerator(g) -> {
        val cfs = lowerAsyncGenerator(g, pool)
        for cf in cfs.toArray() {
          result.add(cf)
        }
      }
      case LPTestModule(className, slots) -> {
        // B126: emit the test-module class (annotated stubs) plus the
        // @LyricTest annotation class so both land in the same JAR.
        result.add(lowerTestModuleClass(className, slots, pool))
        result.add(lyricTestAnnotationClass(pool))
      }
      case LPInterface(iface) -> {
        result.add(lowerInterface(iface, pool))
      }
      case LPClosureClass(c) -> {
        result.add(lowerClosure(c, pool))
      }
    }
  }

  result
}
