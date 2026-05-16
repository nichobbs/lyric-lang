// jvm/lowering.l — Stage B3 JVM type descriptors and instruction lowering.
//
// Provides:
//   • `JvmType` — typed representation of JVM field/return types.
//   • `LInsn` — high-level instruction union; `lowerInsn` resolves pool refs.
//   • `LField` / `LFunc` / `LRecord` — typed class/method/field descriptors.
//   • `lowerFunc` — lowers an LFunc to a MethodInfo with a Code attribute.
//   • `lowerRecord` — lowers an LRecord to a ClassFile with a synthesised ctor.
//   • `LPTestModule` (B126) — test-module package item; see `Jvm.TestEngine`.

package Jvm.Lowering

import Std.Core
import Std.Collections
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
    case JBoolean         -> "Z"
    case JByte            -> "B"
    case JChar            -> "C"
    case JShort           -> "S"
    case JInt             -> "I"
    case JLong            -> "J"
    case JFloat           -> "F"
    case JDouble          -> "D"
    case JVoid            -> "V"
    case JRef(cls)        -> "L" + cls + ";"
    case JArray(el)       -> "[" + typeDescriptor(el)
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
  case LDup

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
}

// ── Type helpers (no OR patterns) ────────────────────────────────────────────

// Returns 2 for double-width types (long, double), 1 for all others.
pub func fieldSlotSize(t: in JvmType): Int {
  match t {
    case JLong   -> 2
    case JDouble -> 2
    case JBoolean -> 1
    case JByte    -> 1
    case JChar    -> 1
    case JShort   -> 1
    case JInt     -> 1
    case JFloat   -> 1
    case JVoid    -> 0
    case JRef(_)  -> 1
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
    case LLabel(n)      -> { emitLabel(asm, n); resetStack(asm) }
    case LNop           -> emitNop(asm)
    case LReturn        -> emitReturn(asm)
    case LIreturn       -> { emitIreturn(asm); trackStack(asm, -1) }
    case LLreturn       -> { emitLreturn(asm); trackStack(asm, -2) }
    case LDreturn       -> { emitDreturn(asm); trackStack(asm, -2) }
    case LAreturn       -> { emitAreturn(asm); trackStack(asm, -1) }
    case LAthrow        -> { emitAthrow(asm);  trackStack(asm, -1) }

    case LIconst(v)     -> { emitPushInt(asm, v);    trackStack(asm, 1)  }
    case LLconst(v)     -> { emitPushLong(asm, v);   trackStack(asm, 2)  }
    case LFconst(v)     -> { emitPushFloat(asm, v);  trackStack(asm, 1)  }
    case LDconst(v)     -> { emitPushDouble(asm, v); trackStack(asm, 2)  }
    case LPushString(s) -> { emitPushString(asm, s); trackStack(asm, 1)  }

    case LIload(s)      -> { emitIload(asm, s); trackStack(asm, 1)  }
    case LLload(s)      -> { emitLload(asm, s); trackStack(asm, 2)  }
    case LDload(s)      -> { emitDload(asm, s); trackStack(asm, 2)  }
    case LAload(s)      -> { emitAload(asm, s); trackStack(asm, 1)  }
    case LIstore(s)     -> { emitIstore(asm, s); trackStack(asm, -1) }
    case LLstore(s)     -> { emitLstore(asm, s); trackStack(asm, -2) }
    case LDstore(s)     -> { emitDstore(asm, s); trackStack(asm, -2) }
    case LAstore(s)         -> { emitAstore(asm, s); trackStack(asm, -1) }
    case LAstoreAs(s, _cls) -> { emitAstore(asm, s); trackStack(asm, -1) }

    case LPop           -> { emitPop(asm); trackStack(asm, -1) }
    case LDup           -> { emitDup(asm); trackStack(asm, 1)  }

    case LIadd          -> { emitIadd(asm);  trackStack(asm, -1) }
    case LIsub          -> { emitIsub(asm);  trackStack(asm, -1) }
    case LImul          -> { emitImul(asm);  trackStack(asm, -1) }
    case LIdiv          -> { emitIdiv(asm);  trackStack(asm, -1) }
    case LIrem          -> { emitIrem(asm);  trackStack(asm, -1) }
    case LIneg          -> emitIneg(asm)
    case LIinc(s, d)    -> emitIinc(asm, s, d)
    case LI2l           -> { emitI2l(asm); trackStack(asm, 1)  }
    case LI2d           -> { emitI2d(asm); trackStack(asm, 1)  }
    case LL2i           -> { emitL2i(asm); trackStack(asm, -1) }

    case LLadd          -> { emitLadd(asm); trackStack(asm, -2) }
    case LLsub          -> { emitLsub(asm); trackStack(asm, -2) }
    case LLmul          -> { emitLmul(asm); trackStack(asm, -2) }
    case LLdiv          -> { emitLdiv(asm); trackStack(asm, -2) }

    case LDadd          -> { emitDadd(asm); trackStack(asm, -2) }
    case LDsub          -> { emitDsub(asm); trackStack(asm, -2) }
    case LDmul          -> { emitDmul(asm); trackStack(asm, -2) }
    case LDdiv          -> { emitDdiv(asm); trackStack(asm, -2) }

    case LFload(s)      -> { emitFload(asm, s); trackStack(asm, 1)  }
    case LFstore(s)     -> { emitFstore(asm, s); trackStack(asm, -1) }
    case LFreturn       -> { emitFreturn(asm); trackStack(asm, -1) }
    case LFadd          -> { emitFadd(asm); trackStack(asm, -1) }
    case LFsub          -> { emitFsub(asm); trackStack(asm, -1) }
    case LFmul          -> { emitFmul(asm); trackStack(asm, -1) }
    case LFdiv          -> { emitFdiv(asm); trackStack(asm, -1) }
    case LFrem          -> { emitFrem(asm); trackStack(asm, -1) }
    case LFneg          -> emitFneg(asm)

    case LIand          -> { emitIand(asm);  trackStack(asm, -1) }
    case LIor           -> { emitIor(asm);   trackStack(asm, -1) }
    case LIxor          -> { emitIxor(asm);  trackStack(asm, -1) }
    case LIshl          -> { emitIshl(asm);  trackStack(asm, -1) }
    case LIshr          -> { emitIshr(asm);  trackStack(asm, -1) }
    case LIushr         -> { emitIushr(asm); trackStack(asm, -1) }

    case LLneg          -> emitLneg(asm)
    case LLrem          -> { emitLrem(asm);  trackStack(asm, -2) }
    case LLand          -> { emitLand(asm);  trackStack(asm, -2) }
    case LLor           -> { emitLor(asm);   trackStack(asm, -2) }
    case LLxor          -> { emitLxor(asm);  trackStack(asm, -2) }
    case LLshl          -> { emitLshl(asm);  trackStack(asm, -1) }
    case LLshr          -> { emitLshr(asm);  trackStack(asm, -1) }
    case LLushr         -> { emitLushr(asm); trackStack(asm, -1) }
    case LLcmp          -> { emitLcmp(asm);  trackStack(asm, -3) }

    case LDrem          -> { emitDrem(asm);  trackStack(asm, -2) }
    case LDneg          -> emitDneg(asm)
    case LFcmpl         -> { emitFcmpl(asm); trackStack(asm, -1) }
    case LFcmpg         -> { emitFcmpg(asm); trackStack(asm, -1) }
    case LDcmpl         -> { emitDcmpl(asm); trackStack(asm, -3) }
    case LDcmpg         -> { emitDcmpg(asm); trackStack(asm, -3) }

    case LL2f           -> { emitL2f(asm); trackStack(asm, -1) }
    case LL2d           -> emitL2d(asm)
    case LI2f           -> emitI2f(asm)
    case LI2b           -> emitI2b(asm)
    case LI2c           -> emitI2c(asm)
    case LI2s           -> emitI2s(asm)
    case LF2i           -> emitF2i(asm)
    case LF2l           -> { emitF2l(asm); trackStack(asm, 1) }
    case LF2d           -> { emitF2d(asm); trackStack(asm, 1) }
    case LD2i           -> { emitD2i(asm); trackStack(asm, -1) }
    case LD2l           -> emitD2l(asm)
    case LD2f           -> { emitD2f(asm); trackStack(asm, -1) }

    case LGoto(l)           -> emitGoto(asm, l)
    case LIfeq(l)           -> { emitIfeq(asm, l);     trackStack(asm, -1) }
    case LIfne(l)           -> { emitIfne(asm, l);     trackStack(asm, -1) }
    case LIflt(l)           -> { emitIflt(asm, l);     trackStack(asm, -1) }
    case LIfge(l)           -> { emitIfge(asm, l);     trackStack(asm, -1) }
    case LIfgt(l)           -> { emitIfgt(asm, l);     trackStack(asm, -1) }
    case LIfle(l)           -> { emitIfle(asm, l);     trackStack(asm, -1) }
    case LIfIcmpeq(l)       -> { emitIfIcmpeq(asm, l); trackStack(asm, -2) }
    case LIfIcmpne(l)       -> { emitIfIcmpne(asm, l); trackStack(asm, -2) }
    case LIfIcmplt(l)       -> { emitIfIcmplt(asm, l); trackStack(asm, -2) }
    case LIfIcmpge(l)       -> { emitIfIcmpge(asm, l); trackStack(asm, -2) }
    case LIfIcmpgt(l)       -> { emitIfIcmpgt(asm, l); trackStack(asm, -2) }
    case LIfIcmple(l)       -> { emitIfIcmple(asm, l); trackStack(asm, -2) }
    case LIfAcmpeq(l)       -> { emitIfAcmpeq(asm, l); trackStack(asm, -2) }
    case LIfAcmpne(l)       -> { emitIfAcmpne(asm, l); trackStack(asm, -2) }

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
      trackStack(asm, 0)
    }
    case LInvokespecial(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokespecial(asm, idx)
      trackStack(asm, 0)
    }
    case LInvokestatic(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokestatic(asm, idx)
      trackStack(asm, 0)
    }
    case LInvokeinterface(owner, name, ps, ret, argCount) -> {
      val idx = poolIfaceMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokeinterface(asm, idx, argCount)
      trackStack(asm, 0)
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
    case LAconstNull -> { emitAconstNull(asm); trackStack(asm, 1) }

    case LAnewarray(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitAnewarray(asm, idx)
    }
    case LNewarray(tc) -> emitNewarray(asm, tc)
    case LArraylength  -> emitArraylength(asm)

    case LIaload  -> { emitIaload(asm); trackStack(asm, -1) }
    case LLaload  -> emitLaload(asm)
    case LFaload  -> { emitFaload(asm); trackStack(asm, -1) }
    case LDaload  -> emitDaload(asm)
    case LAaload  -> { emitAaload(asm); trackStack(asm, -1) }
    case LBaload  -> { emitBaload(asm); trackStack(asm, -1) }
    case LCaload  -> { emitCaload(asm); trackStack(asm, -1) }
    case LSaload  -> { emitSaload(asm); trackStack(asm, -1) }

    case LIastore  -> { emitIastore(asm); trackStack(asm, -3) }
    case LLastore  -> { emitLastore(asm); trackStack(asm, -4) }
    case LFastore  -> { emitFastore(asm); trackStack(asm, -3) }
    case LDastore  -> { emitDastore(asm); trackStack(asm, -4) }
    case LAastore  -> { emitAastore(asm); trackStack(asm, -3) }
    case LBastore  -> { emitBastore(asm); trackStack(asm, -3) }
    case LCastore  -> { emitCastore(asm); trackStack(asm, -3) }
    case LSastore  -> { emitSastore(asm); trackStack(asm, -3) }

    case LTableswitch(lo, hi, def, cases) -> { emitTableSwitch(asm, lo, hi, def, cases); trackStack(asm, -1) }
    case LLookupswitch(def, pairs) -> { emitLookupSwitch(asm, def, pairs); trackStack(asm, -1) }

    case LTryCatch(_, _, _, _) -> ()  // meta-insn: collected by lowerFunc, no bytecode

    case LBoxInt -> {
      val ps: List[JvmType] = newList()
      ps.add(JInt)
      lowerInsn(LInvokestatic(owner = "java/lang/Integer", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Integer")), asm)
    }
    case LBoxLong -> {
      val ps: List[JvmType] = newList()
      ps.add(JLong)
      lowerInsn(LInvokestatic(owner = "java/lang/Long", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Long")), asm)
    }
    case LBoxFloat -> {
      val ps: List[JvmType] = newList()
      ps.add(JFloat)
      lowerInsn(LInvokestatic(owner = "java/lang/Float", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Float")), asm)
    }
    case LBoxDouble -> {
      val ps: List[JvmType] = newList()
      ps.add(JDouble)
      lowerInsn(LInvokestatic(owner = "java/lang/Double", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Double")), asm)
    }
    case LBoxBool -> {
      val ps: List[JvmType] = newList()
      ps.add(JBoolean)
      lowerInsn(LInvokestatic(owner = "java/lang/Boolean", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Boolean")), asm)
    }
    case LBoxByte -> {
      val ps: List[JvmType] = newList()
      ps.add(JByte)
      lowerInsn(LInvokestatic(owner = "java/lang/Byte", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Byte")), asm)
    }
    case LBoxChar -> {
      val ps: List[JvmType] = newList()
      ps.add(JChar)
      lowerInsn(LInvokestatic(owner = "java/lang/Character", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Character")), asm)
    }
    case LBoxShort -> {
      val ps: List[JvmType] = newList()
      ps.add(JShort)
      lowerInsn(LInvokestatic(owner = "java/lang/Short", name = "valueOf", params = ps, ret = JRef(className = "java/lang/Short")), asm)
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
    case LYield ->
      // LYield is a meta-insn for async generators; it must not appear in
      // general-purpose lowering.  Callers should use lowerAsyncGenerator
      // which handles LYield inside RunBody bodies.
      panic("LYield used outside an async-generator body")
  }
}

// ── LField / LFunc / LRecord ─────────────────────────────────────────────────

pub record LField {
  flags:      Int
  name:       String
  fieldType:  JvmType
}

pub record LFunc {
  flags:      Int
  name:       String
  params:     List[JvmType]
  ret:        JvmType
  insns:      List[LInsn]
  maxStack:   Int
  maxLocals:  Int
}

pub record LRecord {
  className:  String
  fields:     List[LField]
  methods:    List[LFunc]
}

// ── Type helpers (no OR patterns) ────────────────────────────────────────────

// Emit the appropriate load instruction for parameter slot `slot` of type `t`.
func emitFieldLoad(t: in JvmType, slot: in Int, asm: in MethodAssembler): Unit {
  match t {
    case JLong    -> lowerInsn(LLload(slot = slot), asm)
    case JDouble  -> lowerInsn(LDload(slot = slot), asm)
    case JBoolean -> lowerInsn(LIload(slot = slot), asm)
    case JByte    -> lowerInsn(LIload(slot = slot), asm)
    case JChar    -> lowerInsn(LIload(slot = slot), asm)
    case JShort   -> lowerInsn(LIload(slot = slot), asm)
    case JInt     -> lowerInsn(LIload(slot = slot), asm)
    case JFloat   -> lowerInsn(LFload(slot = slot), asm)
    case JVoid    -> ()
    case JRef(_)  -> lowerInsn(LAload(slot = slot), asm)
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
    case JBoolean   -> VInteger
    case JByte      -> VInteger
    case JChar      -> VInteger
    case JShort     -> VInteger
    case JInt       -> VInteger
    case JFloat     -> VFloat
    case JLong      -> VLong
    case JDouble    -> VDouble
    case JVoid      -> VTop
    case JRef(cls)  -> VObject(className = cls)
    case JArray(el) -> VObject(className = "[" + typeDescriptor(el))
  }
}

// Add `l` to the Map-as-set `targets` if not already present.
func addTarget(targets: in Map[String, Bool], l: in String): Unit {
  match mapGet(targets, l) {
    case None    -> targets.add(l, true)
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
      case LLabel(l)      -> addTarget(targets, l)
      case LGoto(l)       -> addTarget(targets, l)
      case LIfeq(l)       -> addTarget(targets, l)
      case LIfne(l)       -> addTarget(targets, l)
      case LIflt(l)       -> addTarget(targets, l)
      case LIfge(l)       -> addTarget(targets, l)
      case LIfgt(l)       -> addTarget(targets, l)
      case LIfle(l)       -> addTarget(targets, l)
      case LIfIcmpeq(l)   -> addTarget(targets, l)
      case LIfIcmpne(l)   -> addTarget(targets, l)
      case LIfIcmplt(l)   -> addTarget(targets, l)
      case LIfIcmpge(l)   -> addTarget(targets, l)
      case LIfIcmpgt(l)   -> addTarget(targets, l)
      case LIfIcmple(l)   -> addTarget(targets, l)
      case LIfAcmpeq(l)   -> addTarget(targets, l)
      case LIfAcmpne(l)   -> addTarget(targets, l)
      case LTableswitch(_, _, def, cases) -> {
        addTarget(targets, def)
        addLabelTargets(targets, cases)
      }
      case LLookupswitch(def, pairs) -> {
        addTarget(targets, def)
        addPairLabelTargets(targets, pairs)
      }
      case _              -> ()
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
      case LIload(s)       -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LLload(s)       -> { if s + 2 > maxSlot { maxSlot = s + 2 } }
      case LFload(s)       -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LDload(s)       -> { if s + 2 > maxSlot { maxSlot = s + 2 } }
      case LAload(s)       -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LIstore(s)      -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LLstore(s)      -> { if s + 2 > maxSlot { maxSlot = s + 2 } }
      case LFstore(s)      -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LDstore(s)      -> { if s + 2 > maxSlot { maxSlot = s + 2 } }
      case LAstore(s)      -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LAstoreAs(s, _) -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case LIinc(s, _)     -> { if s + 1 > maxSlot { maxSlot = s + 1 } }
      case _               -> ()
    }
    i = i + 1
  }
  // Account for parameter slots (always allocated at 0..N-1).
  val paramSlots = slotSum(f.params)
  if paramSlots > maxSlot { maxSlot = paramSlots }
  // For virtual methods slot 0 is `this`; ACC_STATIC = 0x0008.
  val isStatic = (f.flags / 8) % 2 == 1
  if not isStatic and maxSlot < 1 { maxSlot = 1 }
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
  val tcStartLabels:   List[String] = newList()
  val tcEndLabels:     List[String] = newList()
  val tcHandlerLabels: List[String] = newList()
  val tcCatchClasses:  List[String] = newList()
  val handlerTargets:  Map[String, String] = newMap()  // handlerLabel -> catchClass
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
      case VLong   -> { paramSlotCount = paramSlotCount + 2 }
      case VDouble -> { paramSlotCount = paramSlotCount + 2 }
      case _       -> { paramSlotCount = paramSlotCount + 1 }
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
      case _ -> { preSlot = preSlot + 1 }
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
          case VLong   -> { slotIdx = slotIdx + 2 }
          case VDouble -> { slotIdx = slotIdx + 2 }
          case _       -> { slotIdx = slotIdx + 1 }
        }
      }
      case None -> { slotIdx = slotIdx + 1 }
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
  val smBuf = writerNew()   // raw frame bytes (no leading count)
  var smCount = 0
  var prevOffset = -1       // initial implicit frame is at offset -1

  var si = 0
  while si < f.insns.count {
    match f.insns[si] {
      case LLabel(l) -> {
        if branchTargets.containsKey(l) {
          match mapGet(ar.labelOffsets, l) {
            case Some(off) -> {
              val delta = off - prevOffset - 1
              writerByte(smBuf, 255)           // full_frame tag
              writerU2(smBuf, delta)           // offset_delta
              writerU2(smBuf, frameLocals.count)
              var vi = 0
              while vi < frameLocals.count {
                emitVerifierTypeBc(frameLocals[vi], pool, smBuf)
                vi = vi + 1
              }
              match mapGet(handlerTargets, l) {
                case Some(cc) -> {
                  writerU2(smBuf, 1)             // 1 stack item: the caught exception
                  val exClass = if cc == "" { "java/lang/Throwable" } else { cc }
                  emitVerifierTypeBc(VObject(className = exClass), pool, smBuf)
                }
                case None -> {
                  writerU2(smBuf, 0)             // stack items = 0 (empty)
                }
              }
              smCount = smCount + 1
              prevOffset = off
            }
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
    si = si + 1
  }

  // Build the Code attribute body.  If there are StackMapTable entries,
  // embed them as a nested attribute (JVMS §4.7.3, §4.7.4).
  val codeW = writerNew()
  writerU2(codeW, actualMaxStack)
  writerU2(codeW, actualMaxLocals)
  writerU4(codeW, ar.codeBytes.count)
  writerByteList(codeW, ar.codeBytes)
  writerU2(codeW, tcStartLabels.count)   // exception_table_length
  var tci = 0
  while tci < tcStartLabels.count {
    val spOff = match mapGet(ar.labelOffsets, tcStartLabels[tci]) { case Some(v) -> v case None -> 0 }
    val epOff = match mapGet(ar.labelOffsets, tcEndLabels[tci])   { case Some(v) -> v case None -> 0 }
    val hpOff = match mapGet(ar.labelOffsets, tcHandlerLabels[tci]) { case Some(v) -> v case None -> 0 }
    val cc    = tcCatchClasses[tci]
    val ct    = if cc == "" { 0 } else { poolClass(pool, cc) }
    writerU2(codeW, spOff)
    writerU2(codeW, epOff)
    writerU2(codeW, hpOff)
    writerU2(codeW, ct)
    tci = tci + 1
  }
  if smCount > 0 {
    writerU2(codeW, 1)             // attributes_count = 1
    writerU2(codeW, poolUtf8(pool, "StackMapTable"))
    val smBytes = writerToList(smBuf)
    writerU4(codeW, 2 + smBytes.count)  // length = u2(count) + frames
    writerU2(codeW, smCount)
    writerByteList(codeW, smBytes)
  } else {
    writerU2(codeW, 0)             // attributes_count = 0
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
  lowerInsn(LInvokespecial(
    owner  = "java/lang/Object",
    name   = "<init>",
    params = objInitPs,
    ret    = JVoid
  ), ctorAsm)

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
  val ctorMethod = makeMethodInfo(
    ACC_PUBLIC, "<init>", buildDescriptor(ctorParams, JVoid), ctorAttrs
  )
  methods.add(ctorMethod)

  // ── Emit explicit methods ──────────────────────────────────────────────────
  for fn in r.methods.toArray() {
    methods.add(lowerFunc(fn, pool))
  }

  // ── Build FieldInfo list ───────────────────────────────────────────────────
  val cfFields: List[FieldInfo] = newList()
  for fld in r.fields.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(
      ACC_PUBLIC, fld.name, typeDescriptor(fld.fieldType), fa
    ))
  }

  makeClassFull(r.className, cfFields, methods)
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
  fields:    List[LField]   // non-lock data fields (will be emitted as private)
  entries:   List[LFunc]    // each insns list pushes the result; no return insn
}

pub record LWireBinding {
  name:    String
  valType: JvmType
  insns:   List[LInsn]      // push the constructed value; no return insn
}

pub record LWire {
  className: String
  bindings:  List[LWireBinding]
  exposes:   List[String]   // binding names to expose as public static accessors
}

// Store a value of type `t` to local slot `slot`.
func storeInsn(t: in JvmType, slot: in Int): LInsn {
  match t {
    case JLong    -> LLstore(slot = slot)
    case JDouble  -> LDstore(slot = slot)
    case JBoolean -> LIstore(slot = slot)
    case JByte    -> LIstore(slot = slot)
    case JChar    -> LIstore(slot = slot)
    case JShort   -> LIstore(slot = slot)
    case JInt     -> LIstore(slot = slot)
    case JFloat   -> LFstore(slot = slot)
    case JVoid    -> LNop
    case JRef(_)  -> LAstore(slot = slot)
    case JArray(_) -> LAstore(slot = slot)
  }
}

// Load a value of type `t` from local slot `slot`.
func loadInsn(t: in JvmType, slot: in Int): LInsn {
  match t {
    case JLong    -> LLload(slot = slot)
    case JDouble  -> LDload(slot = slot)
    case JBoolean -> LIload(slot = slot)
    case JByte    -> LIload(slot = slot)
    case JChar    -> LIload(slot = slot)
    case JShort   -> LIload(slot = slot)
    case JInt     -> LIload(slot = slot)
    case JFloat   -> LFload(slot = slot)
    case JVoid    -> LNop
    case JRef(_)  -> LAload(slot = slot)
    case JArray(_) -> LAload(slot = slot)
  }
}

// Return instruction appropriate for return type `t`.
func returnInsn(t: in JvmType): LInsn {
  match t {
    case JLong    -> LLreturn
    case JDouble  -> LDreturn
    case JBoolean -> LIreturn
    case JByte    -> LIreturn
    case JChar    -> LIreturn
    case JShort   -> LIreturn
    case JInt     -> LIreturn
    case JFloat   -> LFreturn
    case JVoid    -> LReturn
    case JRef(_)  -> LAreturn
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
  wInsns.add(LInvokevirtual(
    owner  = "java/util/concurrent/locks/ReentrantLock",
    name   = "lock",
    params = lockPs,
    ret    = JVoid
  ))

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
  wInsns.add(LInvokevirtual(
    owner  = "java/util/concurrent/locks/ReentrantLock",
    name   = "unlock",
    params = lockPs,
    ret    = JVoid
  ))

  // Reload result and return
  if fieldSlotSize(ef.ret) > 0 {
    wInsns.add(loadInsn(ef.ret, resultSlot))
  }
  wInsns.add(returnInsn(ef.ret))

  val wFunc = LFunc(
    flags     = ef.flags,
    name      = ef.name,
    params    = ef.params,
    ret       = ef.ret,
    insns     = wInsns,
    maxStack  = ef.maxStack + 2,   // +2 headroom for lock acquire/release
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
  lowerInsn(LInvokespecial(
    owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid
  ), ctorAsm)

  // aload_0; new RL; dup; invokespecial RL.<init>; putfield _lock
  lowerInsn(LAload(slot = 0), ctorAsm)
  lowerInsn(LNew(className = "java/util/concurrent/locks/ReentrantLock"), ctorAsm)
  lowerInsn(LDup, ctorAsm)
  val rlPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(
    owner  = "java/util/concurrent/locks/ReentrantLock",
    name   = "<init>",
    params = rlPs,
    ret    = JVoid
  ), ctorAsm)
  lowerInsn(LPutfield(owner = p.className, name = "_lock", t = lockType), ctorAsm)

  // Zero-initialise each data field
  for fld in p.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    match fld.fieldType {
      case JInt     -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JBoolean -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JByte    -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JChar    -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JShort   -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JFloat   -> lowerInsn(LFconst(v = 0.0), ctorAsm)
      case JLong    -> { lowerInsn(LIconst(v = 0), ctorAsm); lowerInsn(LI2l, ctorAsm) }
      case JDouble  -> { lowerInsn(LIconst(v = 0), ctorAsm); lowerInsn(LI2d, ctorAsm) }
      case JVoid    -> ()
      case JRef(_)  -> lowerInsn(LAconstNull, ctorAsm)
      case JArray(_) -> lowerInsn(LAconstNull, ctorAsm)
    }
    match fld.fieldType {
      case JVoid -> ()
      case _     -> lowerInsn(LPutfield(owner = p.className, name = fld.name, t = fld.fieldType), ctorAsm)
    }
  }

  lowerInsn(LReturn, ctorAsm)

  // maxStack=3 (aload_0 + new RL + dup before invokespecial), maxLocals=1 (this)
  val ctorCode = assembleCode(ctorAsm, 3, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamsEmpty: List[JvmType] = newList()
  val ctorMethod = makeMethodInfo(
    ACC_PUBLIC, "<init>", buildDescriptor(ctorParamsEmpty, JVoid), ctorAttrs
  )
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

  // Static fields (private static), one per binding
  for b in w.bindings.toArray() {
    val fa: List[Attribute] = newList()
    cfFields.add(makeFieldInfo(
      ACC_PRIVATE + ACC_STATIC, b.name, typeDescriptor(b.valType), fa
    ))
  }

  // Private constructor (prevents external instantiation)
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val objPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(
    owner = "java/lang/Object", name = "<init>", params = objPs, ret = JVoid
  ), ctorAsm)
  lowerInsn(LReturn, ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 1, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamsEmpty: List[JvmType] = newList()
  val ctorMethod = makeMethodInfo(
    ACC_PRIVATE, "<init>", buildDescriptor(ctorParamsEmpty, JVoid), ctorAttrs
  )
  methods.add(ctorMethod)

  // bootstrap()V — run each binding's insns and store to the static field
  val bsAsm = newAssembler(pool)
  for b in w.bindings.toArray() {
    for insn in b.insns.toArray() {
      lowerInsn(insn, bsAsm)
    }
    lowerInsn(LPutstatic(owner = w.className, name = b.name, t = b.valType), bsAsm)
  }
  lowerInsn(LReturn, bsAsm)
  val bsCode = assembleCode(bsAsm, 3, 0)
  val bsAttrs: List[Attribute] = newList()
  bsAttrs.add(bsCode)
  val bsParamsEmpty: List[JvmType] = newList()
  val bsMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "bootstrap",
    buildDescriptor(bsParamsEmpty, JVoid),
    bsAttrs
  )
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
      val accMethod = makeMethodInfo(
        ACC_PUBLIC + ACC_STATIC,
        b.name,
        buildDescriptor(accParamsEmpty, b.valType),
        accAttrs
      )
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
  caseName:   String         // simple case name (e.g. "Some")
  fields:     List[LField]   // case payload fields
}

pub record LUnion {
  baseName:   String           // JVM internal binary name (e.g. "Option")
  cases:      List[LUnionCase]
  methods:    List[LFunc]      // methods on the base class
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
    cfFields.add(makeFieldInfo(
      ACC_PUBLIC, fld.name, typeDescriptor(fld.fieldType), fa
    ))
  }

  // Synthesise <init>(field…)V — same logic as lowerRecord but super is baseName
  val ctorAsm = newAssembler(pool)
  lowerInsn(LAload(slot = 0), ctorAsm)
  val superPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(
    owner  = baseName,
    name   = "<init>",
    params = superPs,
    ret    = JVoid
  ), ctorAsm)

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
  val ctorMethod = makeMethodInfo(
    ACC_PUBLIC, "<init>", buildDescriptor(ctorParams, JVoid), ctorAttrs
  )

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
  lowerInsn(LInvokespecial(
    owner  = "java/lang/Object",
    name   = "<init>",
    params = objPs,
    ret    = JVoid
  ), baseCtorAsm)
  lowerInsn(LReturn, baseCtorAsm)

  val baseCtorCode = assembleCode(baseCtorAsm, 1, 1)
  val baseCtorAttrs: List[Attribute] = newList()
  baseCtorAttrs.add(baseCtorCode)
  val baseCtorPs: List[JvmType] = newList()
  val baseCtor = makeMethodInfo(
    ACC_PUBLIC, "<init>", buildDescriptor(baseCtorPs, JVoid), baseCtorAttrs
  )
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
  boundSlot:  Int
  skipLabel:  String
  bodyInsns:  List[LInsn]
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
  asm:       in MethodAssembler,
  scrutSlot: in Int,
  arms:      in List[LMatchArm],
  endLabel:  in String
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
  key:       Int
  caseLabel: String
  bodyInsns: List[LInsn]
}

// Emit a lookupswitch dispatch over integer cases.  Each arm is emitted as:
//   caseLabel: [bodyInsns] goto endLabel
// The default case follows all arms:
//   defaultLabel: [defaultInsns] goto endLabel
pub func lowerMatchInt(
  asm:          in MethodAssembler,
  scrutSlot:    in Int,
  arms:         in List[LIntArm],
  defaultLabel: in String,
  defaultInsns: in List[LInsn],
  endLabel:     in String
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
  key:       String
  skipLabel: String
  bodyInsns: List[LInsn]
}

// Emit a linear equals-chain dispatch over string cases.
// For each arm: aload scrutSlot; ldc key; invokevirtual equals; ifeq skipLabel;
//   [bodyInsns] goto endLabel; skipLabel:
// Followed by [defaultInsns] goto endLabel.
pub func lowerMatchStr(
  asm:          in MethodAssembler,
  scrutSlot:    in Int,
  arms:         in List[LStrArm],
  defaultInsns: in List[LInsn],
  endLabel:     in String
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
  ifaceClass:   String
  ifaceMethod:  String
  captures:     List[LClosureCapture]
  methodParams: List[JvmType]
  methodRet:    JvmType
  bodyInsns:    List[LInsn]
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
      case JInt     -> { emitIload(asm, slot); slot = slot + 1 }
      case JLong    -> { emitLload(asm, slot); slot = slot + 2 }
      case JFloat   -> { emitFload(asm, slot); slot = slot + 1 }
      case JDouble  -> { emitDload(asm, slot); slot = slot + 2 }
      case JBoolean -> { emitIload(asm, slot); slot = slot + 1 }
      case JByte    -> { emitIload(asm, slot); slot = slot + 1 }
      case JChar    -> { emitIload(asm, slot); slot = slot + 1 }
      case JShort   -> { emitIload(asm, slot); slot = slot + 1 }
      case JVoid    -> ()
      case JRef(_)   -> { emitAload(asm, slot); slot = slot + 1 }
      case JArray(_) -> { emitAload(asm, slot); slot = slot + 1 }
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
  val asm = newAssembler(pool)
  lowerBodyInsns(asm, c.bodyInsns)
  val paramSlots = 1 + slotSum(c.methodParams)
  val codeAttr = assembleCodeInferred(asm, paramSlots)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  makeMethodInfo(ACC_PUBLIC, c.ifaceMethod, buildDescriptor(c.methodParams, c.methodRet), attrs)
}

pub func lowerClosure(c: in LClosure, pool: in Pool): ClassFile {
  val fields  = lowerClosureCaptures(c.captures, pool)
  val ctor    = lowerClosureCtor(c, pool)
  val method  = lowerClosureMethod(c, pool)
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
  val idx = poolMethodref(asm.pool, "java/lang/Thread", "startVirtualThread",
    "(Ljava/lang/Runnable;)Ljava/lang/Thread;")
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
  wrapperClass:   String
  underlyingType: JvmType
}

pub func lowerDistinctType(d: in LDistinctType, pool: in Pool): ClassFile {
  val valueDesc = typeDescriptor(d.underlyingType)
  val fieldIdx  = poolFieldref(pool, d.wrapperClass, "$value", valueDesc)

  // private final <underlying> $value
  val fAttrs: List[Attribute] = newList()
  val valueField = makeFieldInfo(ACC_PRIVATE + ACC_FINAL, "$value", valueDesc, fAttrs)

  // public <init>(<underlying>)V
  val ctorAsm    = newAssembler(pool)
  val objCtorIdx = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  emitAload(ctorAsm, 0)
  emitInvokespecial(ctorAsm, objCtorIdx)
  emitAload(ctorAsm, 0)
  match d.underlyingType {
    case JLong    -> emitLload(ctorAsm, 1)
    case JDouble  -> emitDload(ctorAsm, 1)
    case JFloat   -> emitFload(ctorAsm, 1)
    case JBoolean -> emitIload(ctorAsm, 1)
    case JByte    -> emitIload(ctorAsm, 1)
    case JChar    -> emitIload(ctorAsm, 1)
    case JShort   -> emitIload(ctorAsm, 1)
    case JInt     -> emitIload(ctorAsm, 1)
    case JVoid    -> ()
    case JRef(_)  -> emitAload(ctorAsm, 1)
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
    case JLong    -> emitLreturn(accAsm)
    case JDouble  -> emitDreturn(accAsm)
    case JFloat   -> emitFreturn(accAsm)
    case JBoolean -> emitIreturn(accAsm)
    case JByte    -> emitIreturn(accAsm)
    case JChar    -> emitIreturn(accAsm)
    case JShort   -> emitIreturn(accAsm)
    case JInt     -> emitIreturn(accAsm)
    case JVoid    -> ()
    case JRef(_)  -> emitAreturn(accAsm)
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
    flags        = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass    = d.wrapperClass,
    superClass   = "java/lang/Object",
    interfaces   = newList(),
    fields       = fields,
    methods      = methods,
    attrs        = newList()
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
  wrapperClass:   String
  underlyingType: JvmType
  lo:             Int
  hi:             Int
}

pub func lowerRangeType(r: in LRangeType, pool: in Pool): ClassFile {
  val valueDesc = typeDescriptor(r.underlyingType)
  val fieldIdx  = poolFieldref(pool, r.wrapperClass, "$value", valueDesc)
  val iaeClass  = "java/lang/IllegalArgumentException"
  val iaeIdx    = poolClass(pool, iaeClass)
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
    case JLong   -> emitLreturn(accAsm)
    case JDouble -> emitDreturn(accAsm)
    case JFloat  -> emitFreturn(accAsm)
    case _       -> emitIreturn(accAsm)
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
    flags        = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass    = r.wrapperClass,
    superClass   = "java/lang/Object",
    interfaces   = newList(),
    fields       = fields,
    methods      = methods,
    attrs        = newList()
  )
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
  name:      String
  fieldType: JvmType
}

pub record LOpaqueType {
  className: String
  fields:    List[LOpaqueField]
}

// Package-private constructor: aload_0 → Object.<init>() → for each field: aload_0, load param, putfield → return.
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
      case JInt     -> { emitIload(asm, slot); slot = slot + 1 }
      case JLong    -> { emitLload(asm, slot); slot = slot + 2 }
      case JFloat   -> { emitFload(asm, slot); slot = slot + 1 }
      case JDouble  -> { emitDload(asm, slot); slot = slot + 2 }
      case JBoolean -> { emitIload(asm, slot); slot = slot + 1 }
      case JByte    -> { emitIload(asm, slot); slot = slot + 1 }
      case JChar    -> { emitIload(asm, slot); slot = slot + 1 }
      case JShort   -> { emitIload(asm, slot); slot = slot + 1 }
      case JVoid    -> ()
      case JRef(_)   -> { emitAload(asm, slot); slot = slot + 1 }
      case JArray(_) -> { emitAload(asm, slot); slot = slot + 1 }
    }
    emitPutfield(asm, fIdx)
    i = i + 1
  }
  emitReturn(asm)
  val maxL = slot  // this + all param slots
  val codeAttr = assembleCode(asm, 3, maxL)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val ctorPs: List[JvmType] = newList()
  var ci = 0
  while ci < o.fields.count {
    ctorPs.add(o.fields[ci].fieldType)
    ci = ci + 1
  }
  makeMethodInfo(0, "<init>", buildDescriptor(ctorPs, JVoid), attrs)
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
    case JLong    -> emitLreturn(asm)
    case JDouble  -> emitDreturn(asm)
    case JFloat   -> emitFreturn(asm)
    case JBoolean -> emitIreturn(asm)
    case JByte    -> emitIreturn(asm)
    case JChar    -> emitIreturn(asm)
    case JShort   -> emitIreturn(asm)
    case JInt     -> emitIreturn(asm)
    case JVoid    -> ()
    case JRef(_)   -> emitAreturn(asm)
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
    flags        = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass    = o.className,
    superClass   = "java/lang/Object",
    interfaces   = newList(),
    fields       = fields,
    methods      = allMethods,
    attrs        = newList()
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
    case JLong    -> emitLreturn(asm)
    case JDouble  -> emitDreturn(asm)
    case JFloat   -> emitFreturn(asm)
    case JBoolean -> emitIreturn(asm)
    case JByte    -> emitIreturn(asm)
    case JChar    -> emitIreturn(asm)
    case JShort   -> emitIreturn(asm)
    case JInt     -> emitIreturn(asm)
    case JVoid    -> emitReturn(asm)
    case JRef(_)   -> emitAreturn(asm)
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
      case JInt     -> { emitIload(asm, slot); slot = slot + 1 }
      case JLong    -> { emitLload(asm, slot); slot = slot + 2 }
      case JFloat   -> { emitFload(asm, slot); slot = slot + 1 }
      case JDouble  -> { emitDload(asm, slot); slot = slot + 2 }
      case JBoolean -> { emitIload(asm, slot); slot = slot + 1 }
      case JByte    -> { emitIload(asm, slot); slot = slot + 1 }
      case JChar    -> { emitIload(asm, slot); slot = slot + 1 }
      case JShort   -> { emitIload(asm, slot); slot = slot + 1 }
      case JVoid    -> ()
      case JRef(_)   -> { emitAload(asm, slot); slot = slot + 1 }
      case JArray(_) -> { emitAload(asm, slot); slot = slot + 1 }
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
    flags        = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass    = facadeName,
    superClass   = "java/lang/Object",
    interfaces   = newList(),
    fields       = newList(),
    methods      = methods,
    attrs        = newList()
  )
}

// ── B111: lowerSealedUnion (production sealed-interface form) ─────────────────

/// Sealed case (same shape as LUnionCase but targets the sealed-interface form).
pub record LSealedCase {
  caseName: String       // simple case name (e.g. "Circle")
  fields:   List[LField] // payload fields
}

pub record LSealedUnion {
  baseName: String           // sealed interface JVM internal name
  cases:    List[LSealedCase]
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
  variants:  List[String]
}

/// Lower a payload-free enum type to a single JVM enum ClassFile.
pub func lowerEnum(e: in LEnumType, pool: in Pool): ClassFile {
  val cls  = e.className
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
  lowerInsn(LAload(slot = 1), ctorAsm)   // name
  lowerInsn(LIload(slot = 2), ctorAsm)   // ordinal
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
  val enumNewIdx   = poolClass(pool, cls)
  val enumCtorDesc = "(Ljava/lang/String;I)V"
  val enumCtorRef  = poolMethodref(pool, cls, "<init>", enumCtorDesc)
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
  lowerInsn(LInvokevirtual(
    owner = "java/lang/Object", name = "clone",
    params = clinitPs, ret = JRef(className = "java/lang/Object")
  ), valAsm)
  lowerInsn(LCheckcast(className = "[" + clsDesc), valAsm)
  lowerInsn(LAreturn, valAsm)
  val valCode = assembleCode(valAsm, 1, 0)
  val valAttrs: List[Attribute] = newList()
  valAttrs.add(valCode)
  val valRet: List[JvmType] = newList()
  methods.add(makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "values", buildDescriptor(valRet, JArray(JRef(className = cls))), valAttrs))

  // valueOf(String): E — delegates to Enum.valueOf(Class, String)
  val voAsm = newAssembler(pool)
  emitPushClass(voAsm, cls)
  lowerInsn(LAload(slot = 0), voAsm)
  val voPs: List[JvmType] = newList()
  voPs.add(JRef(className = "java/lang/Class"))
  voPs.add(JRef(className = "java/lang/String"))
  lowerInsn(LInvokestatic(owner = "java/lang/Enum", name = "valueOf", params = voPs, ret = JRef(className = "java/lang/Enum")), voAsm)
  lowerInsn(LCheckcast(className = cls), voAsm)
  lowerInsn(LAreturn, voAsm)
  val voCode = assembleCode(voAsm, 2, 1)
  val voAttrs: List[Attribute] = newList()
  voAttrs.add(voCode)
  val voParamPs: List[JvmType] = newList()
  voParamPs.add(JRef(className = "java/lang/String"))
  methods.add(makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "valueOf", buildDescriptor(voParamPs, JRef(className = cls)), voAttrs))

  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags        = ACC_PUBLIC + ACC_SUPER + ACC_FINAL + ACC_ENUM,
    thisClass    = cls,
    superClass   = "java/lang/Enum",
    interfaces   = newList(),
    fields       = cfFields,
    methods      = methods,
    attrs        = newList()
  )
}

// ── B114: lowerNatTag (phantom N_<value> class for value generics) ────────────

pub record LNatTag {
  className: String    // e.g. "N_42"
  value:     Long
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
  fields:    List[LField]
}

/// Lower an `exposed record` to a ClassFile:
/// - ACC_PUBLIC + ACC_SUPER + ACC_FINAL, superClass = java/lang/Record
/// - Fields are NOT name-mangled (no `$` prefix)
/// - Unmangled public accessor methods named after each field
/// - A `Record` class-level attribute listing all components
pub func lowerExposedRecord(r: in LExposedRecord, pool: in Pool): ClassFile {
  val cfFields: List[FieldInfo] = newList()
  val methods:  List[MethodInfo] = newList()
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
  viewTypeName:   String
  fields:         List[LOpaqueField]
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
    ACC_PUBLIC, "toView", buildDescriptor(toViewPs, JRef(className = p.viewTypeName)), toViewAttrs
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
    flags        = opaqueCf.flags,
    thisClass    = opaqueCf.thisClass,
    superClass   = opaqueCf.superClass,
    interfaces   = opaqueCf.interfaces,
    fields       = opaqueCf.fields,
    methods      = opaqueMethods,
    attrs        = opaqueCf.attrs
  )

  result.add(opaqueWithView)
  result.add(viewCf)
  result
}

// ── B118: lowerProtectedWithBarriers (when: Condition-variable barriers) ───────

pub record LBarrierEntry {
  entryFunc:      LFunc        // the wrapped entry method (body insns only; no lock/unlock)
  conditionName:  String       // name for the Condition field (e.g. "_cond_push")
  predicateInsns: List[LInsn]  // pushes Bool: 1=can proceed, 0=must wait
}

pub record LProtectedWithBarriers {
  className: String
  fields:    List[LField]
  barriers:  List[LBarrierEntry]
}

/// Lower a protected type with `when:` Condition-variable barriers.
/// Uses ReentrantLock + one Condition per barrier entry.
/// Entry method pattern: lock, while !predicate { condition.await }, body, signalAll, unlock.
pub func lowerProtectedWithBarriers(p: in LProtectedWithBarriers, pool: in Pool): ClassFile {
  val lockType = JRef(className = "java/util/concurrent/locks/ReentrantLock")
  val condType = JRef(className = "java/util/concurrent/locks/Condition")
  val methods:  List[MethodInfo] = newList()
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
  lowerInsn(LInvokespecial(owner = "java/util/concurrent/locks/ReentrantLock", name = "<init>", params = rlPs, ret = JVoid), ctorAsm)
  lowerInsn(LPutfield(owner = p.className, name = "_lock", t = lockType), ctorAsm)

  // For each barrier: _lock.newCondition() → condition field
  for be in p.barriers.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    lowerInsn(LAload(slot = 0), ctorAsm)
    lowerInsn(LGetfield(owner = p.className, name = "_lock", t = lockType), ctorAsm)
    val ncPs: List[JvmType] = newList()
    lowerInsn(LInvokevirtual(
      owner = "java/util/concurrent/locks/ReentrantLock", name = "newCondition",
      params = ncPs, ret = condType
    ), ctorAsm)
    lowerInsn(LPutfield(owner = p.className, name = be.conditionName, t = condType), ctorAsm)
  }

  // Zero-init data fields
  for fld in p.fields.toArray() {
    lowerInsn(LAload(slot = 0), ctorAsm)
    match fld.fieldType {
      case JInt  -> lowerInsn(LIconst(v = 0), ctorAsm)
      case JLong -> { lowerInsn(LIconst(v = 0), ctorAsm); lowerInsn(LI2l, ctorAsm) }
      case JRef(_) -> lowerInsn(LAconstNull, ctorAsm)
      case _       -> lowerInsn(LIconst(v = 0), ctorAsm)
    }
    match fld.fieldType {
      case JVoid -> ()
      case _     -> lowerInsn(LPutfield(owner = p.className, name = fld.name, t = fld.fieldType), ctorAsm)
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
  val noPs:   List[JvmType] = newList()
  for be in p.barriers.toArray() {
    val ef = be.entryFunc
    val wInsns: List[LInsn] = newList()

    // Pre-initialize the result slot so that StackMapTable frames at barrier branch
    // targets (which appear before the result is stored) declare the slot as live.
    val resultSlot = ef.maxLocals
    if fieldSlotSize(ef.ret) > 0 {
      match ef.ret {
        case JLong    -> { wInsns.add(LLconst(v = 0i64)); wInsns.add(LLstore(slot = resultSlot)) }
        case JDouble  -> { wInsns.add(LDconst(v = 0.0));  wInsns.add(LDstore(slot = resultSlot)) }
        case JFloat   -> { wInsns.add(LFconst(v = 0.0));  wInsns.add(LFstore(slot = resultSlot)) }
        case JRef(cls) -> { wInsns.add(LAconstNull); wInsns.add(LAstoreAs(slot = resultSlot, className = cls)) }
        case JArray(_) -> { wInsns.add(LAconstNull); wInsns.add(LAstore(slot = resultSlot)) }
        case _ -> { wInsns.add(LIconst(v = 0)); wInsns.add(LIstore(slot = resultSlot)) }
      }
    }

    // lock.lock()
    wInsns.add(LAload(slot = 0))
    wInsns.add(LGetfield(owner = p.className, name = "_lock", t = lockType))
    wInsns.add(LInvokevirtual(owner = "java/util/concurrent/locks/ReentrantLock", name = "lock", params = lockPs, ret = JVoid))

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
    wInsns.add(LInvokeinterface(owner = "java/util/concurrent/locks/Condition", name = "awaitUninterruptibly", params = awaitPs, ret = JVoid, argCount = 1))
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
    wInsns.add(LInvokeinterface(owner = "java/util/concurrent/locks/Condition", name = "signalAll", params = sigPs, ret = JVoid, argCount = 1))

    // lock.unlock()
    wInsns.add(LAload(slot = 0))
    wInsns.add(LGetfield(owner = p.className, name = "_lock", t = lockType))
    wInsns.add(LInvokevirtual(owner = "java/util/concurrent/locks/ReentrantLock", name = "unlock", params = lockPs, ret = JVoid))

    // Return result
    if fieldSlotSize(ef.ret) > 0 {
      wInsns.add(loadInsn(ef.ret, resultSlot))
    }
    wInsns.add(returnInsn(ef.ret))

    val wFunc = LFunc(
      flags     = ef.flags,
      name      = ef.name,
      params    = ef.params,
      ret       = ef.ret,
      insns     = wInsns,
      maxStack  = ef.maxStack + 3,
      maxLocals = ef.maxLocals + fieldSlotSize(ef.ret)
    )
    methods.add(lowerFuncForClass(wFunc, p.className, pool))
  }

  makeFinalClass(p.className, cfFields, methods)
}

// ── B119: lowerHotAsync (CompletableFuture thenCompose chain) ────────────────

pub record LHotFunc {
  className:    String       // host class for the async method
  methodName:   String       // name of the async method
  resultType:   JvmType      // the T in CompletableFuture<T>
  stage1Insns:  List[LInsn]  // first stage: pushes the initial value (no return)
  stage2Insns:  List[LInsn]  // second stage: pops one slot, pushes the result (no return)
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
  appInsns.add(LAload(slot = 1))    // push Object arg
  var s2i = 0
  while s2i < h.stage2Insns.count {
    appInsns.add(h.stage2Insns[s2i])
    s2i = s2i + 1
  }
  // Return the result directly (must be an Object on the stack after stage2Insns)
  appInsns.add(LAreturn)

  val appCaptures: List[LClosureCapture] = newList()
  val appParams:   List[JvmType] = newList()
  appParams.add(JRef(className = "java/lang/Object"))

  val applyFuncClass = h.className + "$Stage2"
  val appClosure = LClosure(
    closureClass = applyFuncClass,
    ifaceClass   = "java/util/function/Function",
    ifaceMethod  = "apply",
    captures     = appCaptures,
    methodParams = appParams,
    methodRet    = JRef(className = "java/lang/Object"),
    bodyInsns    = appInsns
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
  lowerInsn(LInvokestatic(
    owner = "java/util/concurrent/CompletableFuture",
    name  = "completedFuture",
    params = cfPs1,
    ret   = cfType
  ), hostAsm)
  // .thenCompose(new Stage2())
  lowerInsn(LNew(className = applyFuncClass), hostAsm)
  lowerInsn(LDup, hostAsm)
  val stage2CtorPs: List[JvmType] = newList()
  lowerInsn(LInvokespecial(owner = applyFuncClass, name = "<init>", params = stage2CtorPs, ret = JVoid), hostAsm)
  val thenPs: List[JvmType] = newList()
  thenPs.add(JRef(className = "java/util/function/Function"))
  lowerInsn(LInvokevirtual(
    owner  = "java/util/concurrent/CompletableFuture",
    name   = "thenApply",
    params = thenPs,
    ret    = cfType
  ), hostAsm)
  lowerInsn(LAreturn, hostAsm)

  val hostPs:   List[JvmType] = newList()
  val hostCode  = assembleCode(hostAsm, 4, 0)
  val hostAttrs: List[Attribute] = newList()
  hostAttrs.add(hostCode)
  val hostMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC, h.methodName,
    buildDescriptor(hostPs, cfType), hostAttrs
  )
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

/// Bootstrap lowering of a Lyric `async func` with `yield`.
///
/// Emits a generator class implementing `java.lang.Iterable<Object>` and
/// `java.util.Iterator<Object>` with an eager `runBody()` that populates a
/// `java.util.ArrayList<Object>` on the first `iterator()` call.
///
/// Also emits a static kickoff method on `hostClass` that instantiates the
/// generator with the given parameters and returns it as `Object`.
///
/// Bootstrap semantics match the MSIL bootstrap (D-progress-259, Gap-4):
/// all `yield` expressions execute eagerly before the first `hasNext()`.
pub func lowerAsyncGenerator(g: in LGenFunc, pool: in Pool): List[ClassFile] {
  val result: List[ClassFile] = newList()
  val genClass  = g.generatorClass
  val objClass  = "java/lang/Object"
  val listClass = "java/util/ArrayList"
  val iterClass = "java/util/Iterator"
  val iterableClass = "java/lang/Iterable"
  val listType  = JRef(className = listClass)
  val objType   = JRef(className = objClass)

  // ── 1. Field declarations ───────────────────────────────────────────────────
  val emptyAttrs: List[Attribute] = newList()
  val valuesDesc = typeDescriptor(listType)
  val posDesc    = typeDescriptor(JInt)

  val fieldsOut: List[FieldInfo] = newList()
  fieldsOut.add(makeFieldInfo(ACC_PRIVATE, "_values", valuesDesc, emptyAttrs))
  fieldsOut.add(makeFieldInfo(ACC_PRIVATE, "_pos",    posDesc,    emptyAttrs))
  var pi = 0
  while pi < g.params.count {
    val p = g.params[pi]
    val pAttrs: List[Attribute] = newList()
    fieldsOut.add(makeFieldInfo(ACC_PUBLIC, p.paramName, typeDescriptor(p.paramType), pAttrs))
    pi = pi + 1
  }

  // ── 2. Constructor <init>(params...)V ───────────────────────────────────────
  val ctorAsm = newAssembler(pool)
  val objCtorIdx = poolMethodref(pool, objClass, "<init>", "()V")
  emitAload(ctorAsm, 0)
  emitInvokespecial(ctorAsm, objCtorIdx)
  // store params into fields
  var slot = 1
  var qi = 0
  while qi < g.params.count {
    val p = g.params[qi]
    val fIdx = poolFieldref(pool, genClass, p.paramName, typeDescriptor(p.paramType))
    emitAload(ctorAsm, 0)
    emitFieldLoad(p.paramType, slot, ctorAsm)
    emitPutfield(ctorAsm, fIdx)
    match p.paramType {
      case JLong   -> { slot = slot + 2 }
      case JDouble -> { slot = slot + 2 }
      case _       -> { slot = slot + 1 }
    }
    qi = qi + 1
  }
  // initialize _values = new ArrayList()
  val listCtorIdx = poolMethodref(pool, listClass, "<init>", "()V")
  val valuesIdx   = poolFieldref(pool, genClass, "_values", valuesDesc)
  emitAload(ctorAsm, 0)
  emitNew(ctorAsm, poolClass(pool, listClass))
  emitDup(ctorAsm)
  emitInvokespecial(ctorAsm, listCtorIdx)
  emitPutfield(ctorAsm, valuesIdx)
  emitReturn(ctorAsm)
  val ctorMaxLocals = slot
  val ctorCode = assembleCode(ctorAsm, 4, ctorMaxLocals)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorParamTypes: List[JvmType] = newList()
  var ri = 0
  while ri < g.params.count {
    ctorParamTypes.add(g.params[ri].paramType)
    ri = ri + 1
  }
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorParamTypes, JVoid), ctorAttrs)

  // ── 3. runBody()V ───────────────────────────────────────────────────────────
  // Body instructions with LYield replaced by ArrayList.add(Object).
  // Slot 0 = this; slot 1 = yield-temp (allocated for each yield).
  val bodyAsm  = newAssembler(pool)
  val addPs: List[JvmType] = newList()
  addPs.add(objType)
  val addBoolType = JBoolean
  val listAddIdx = poolMethodref(pool, listClass, "add", "(Ljava/lang/Object;)Z")
  var bi = 0
  while bi < g.bodyInsns.count {
    val insn = g.bodyInsns[bi]
    match insn {
      case LYield -> {
        // Stack top = yielded value (already evaluated by preceding insns).
        // Box primitive types to Object before storing in ArrayList.
        match g.elemType {
          case JInt     -> lowerInsn(LBoxInt,    bodyAsm)
          case JLong    -> lowerInsn(LBoxLong,   bodyAsm)
          case JFloat   -> lowerInsn(LBoxFloat,  bodyAsm)
          case JDouble  -> lowerInsn(LBoxDouble, bodyAsm)
          case JBoolean -> lowerInsn(LBoxBool,   bodyAsm)
          case JByte    -> lowerInsn(LBoxByte,   bodyAsm)
          case JChar    -> lowerInsn(LBoxChar,   bodyAsm)
          case JShort   -> lowerInsn(LBoxShort,  bodyAsm)
          case _        -> ()   // reference types need no boxing
        }
        // Stack: [..., Object(value)]
        // Emit: this._values.add(value)
        emitAstore(bodyAsm, 1)           // temp = value; stack: [...]
        emitAload(bodyAsm, 0)             // stack: [this]
        emitGetfield(bodyAsm, valuesIdx)  // stack: [ArrayList]
        emitAload(bodyAsm, 1)             // stack: [ArrayList, value]
        emitInvokevirtual(bodyAsm, listAddIdx)  // stack: [boolean]
        emitPop(bodyAsm)                  // stack: []
      }
      case _ -> lowerInsn(insn, bodyAsm)
    }
    bi = bi + 1
  }
  emitReturn(bodyAsm)
  val bodyCode = assembleCode(bodyAsm, 6, 2)
  val bodyAttrs: List[Attribute] = newList()
  bodyAttrs.add(bodyCode)
  val bodyPs: List[JvmType] = newList()
  val runBodyMethod = makeMethodInfo(ACC_PUBLIC, "runBody", buildDescriptor(bodyPs, JVoid), bodyAttrs)

  // ── 4. iterator(): Iterator ─────────────────────────────────────────────────
  // Calls runBody(), resets _pos to 0, returns this.
  val iterAsm   = newAssembler(pool)
  val posIdx    = poolFieldref(pool, genClass, "_pos", posDesc)
  val runBodyIdx = poolMethodref(pool, genClass, "runBody", "()V")
  emitAload(iterAsm, 0)
  emitInvokevirtual(iterAsm, runBodyIdx)
  emitAload(iterAsm, 0)
  emitPushInt(iterAsm, 0)
  emitPutfield(iterAsm, posIdx)
  emitAload(iterAsm, 0)
  emitAreturn(iterAsm)
  val iterPs: List[JvmType] = newList()
  val iterRetType = JRef(className = iterClass)
  val iterCode = assembleCode(iterAsm, 2, 1)
  val iterAttrs: List[Attribute] = newList()
  iterAttrs.add(iterCode)
  val iterMethod = makeMethodInfo(ACC_PUBLIC, "iterator",
    buildDescriptor(iterPs, iterRetType), iterAttrs)

  // ── 5. hasNext(): boolean ───────────────────────────────────────────────────
  val hnAsm = newAssembler(pool)
  val sizePs: List[JvmType] = newList()
  val listSizeIdx = poolMethodref(pool, listClass, "size", "()I")
  emitAload(hnAsm, 0)
  emitGetfield(hnAsm, posIdx)
  emitAload(hnAsm, 0)
  emitGetfield(hnAsm, valuesIdx)
  emitInvokevirtual(hnAsm, listSizeIdx)
  emitIfIcmpge(hnAsm, "hn_false")
  emitIconst(hnAsm, 1)
  emitIreturn(hnAsm)
  emitLabel(hnAsm, "hn_false")
  emitIconst(hnAsm, 0)
  emitIreturn(hnAsm)
  val hnPs: List[JvmType] = newList()
  val hnCode = assembleCode(hnAsm, 2, 1)
  val hnAttrs: List[Attribute] = newList()
  hnAttrs.add(hnCode)
  val hasNextMethod = makeMethodInfo(ACC_PUBLIC, "hasNext",
    buildDescriptor(hnPs, JBoolean), hnAttrs)

  // ── 6. next(): Object ───────────────────────────────────────────────────────
  // Returns _values.get(_pos), then increments _pos.
  val nextAsm = newAssembler(pool)
  val getPs: List[JvmType] = newList()
  getPs.add(JInt)
  val listGetIdx = poolMethodref(pool, listClass, "get", "(I)Ljava/lang/Object;")
  emitAload(nextAsm, 0)
  emitGetfield(nextAsm, valuesIdx)
  emitAload(nextAsm, 0)
  emitGetfield(nextAsm, posIdx)
  emitInvokevirtual(nextAsm, listGetIdx)
  emitAstore(nextAsm, 1)   // store result in temp
  // Increment _pos via getfield + iadd + putfield (_pos is a field, not a local).
  emitAload(nextAsm, 0)
  emitAload(nextAsm, 0)
  emitGetfield(nextAsm, posIdx)
  emitIconst(nextAsm, 1)
  emitIadd(nextAsm)
  emitPutfield(nextAsm, posIdx)
  emitAload(nextAsm, 1)
  emitAreturn(nextAsm)
  val nextPs: List[JvmType] = newList()
  val nextCode = assembleCode(nextAsm, 3, 2)
  val nextAttrs: List[Attribute] = newList()
  nextAttrs.add(nextCode)
  val nextMethod = makeMethodInfo(ACC_PUBLIC, "next",
    buildDescriptor(nextPs, objType), nextAttrs)

  // ── 7. Assemble generator class ────────────────────────────────────────────
  val genMethods: List[MethodInfo] = newList()
  genMethods.add(ctorMethod)
  genMethods.add(runBodyMethod)
  genMethods.add(iterMethod)
  genMethods.add(hasNextMethod)
  genMethods.add(nextMethod)
  val genIfaces: List[String] = newList()
  genIfaces.add(iterableClass)
  genIfaces.add(iterClass)
  // Use Java 5 (version 49) so the verifier does not require StackMapTable
  // for hasNext()'s branch — bootstrap quality, matching lowerRangeType.
  result.add(ClassFile(
    minorVersion = 0,
    majorVersion = 49,
    flags        = ACC_PUBLIC + ACC_SUPER,
    thisClass    = genClass,
    superClass   = "java/lang/Object",
    interfaces   = genIfaces,
    fields       = fieldsOut,
    methods      = genMethods,
    attrs        = newList()
  ))

  // ── 8. Kickoff method on host class ────────────────────────────────────────
  val kickAsm = newAssembler(pool)
  val genCtorIdx = poolMethodref(pool, genClass, "<init>", buildDescriptor(ctorParamTypes, JVoid))
  val genClassIdx = poolClass(pool, genClass)
  emitNew(kickAsm, genClassIdx)
  emitDup(kickAsm)
  var ki = 0
  var kslot = 0   // static method: params start at slot 0 (no `this`)
  while ki < g.params.count {
    emitFieldLoad(g.params[ki].paramType, kslot, kickAsm)
    match g.params[ki].paramType {
      case JLong   -> { kslot = kslot + 2 }
      case JDouble -> { kslot = kslot + 2 }
      case _       -> { kslot = kslot + 1 }
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
  val kickCode = assembleCode(kickAsm, 4, kslot)
  val kickAttrs: List[Attribute] = newList()
  kickAttrs.add(kickCode)
  val kickMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, g.methodName,
    buildDescriptor(kickPs, objType), kickAttrs)
  val kickMethods: List[MethodInfo] = newList()
  kickMethods.add(kickMethod)
  result.add(makeClassWithMethods(g.hostClass, kickMethods))
  result
}

// ── B120: lowerStructuredScope (StructuredTaskScope.ShutdownOnFailure) ────────

/// Emit bytecode to open a `StructuredTaskScope.ShutdownOnFailure`, fork
/// each callable class (which must implement `Callable`), call join() and
/// throwIfFailed(), then close the scope.
/// The scope reference is stored in `scopeSlot`; each forked task is stored
/// in successive local slots starting at `firstTaskSlot`.
pub func lowerScopeBlock(
  asm:           in MethodAssembler,
  callableNames: in List[String],
  scopeSlot:     in Int,
  firstTaskSlot: in Int
): Unit {
  val scopeClass = "java/util/concurrent/StructuredTaskScope$ShutdownOnFailure"
  val scopePs:   List[JvmType] = newList()

  // new ShutdownOnFailure(); store to scopeSlot
  emitNew(asm, poolClass(asm.pool, scopeClass))
  emitDup(asm)
  emitInvokespecial(asm, poolMethodref(asm.pool, scopeClass, "<init>", "()V"))
  emitAstore(asm, scopeSlot)

  // fork each callable
  var taskSlot = firstTaskSlot
  for callableName in callableNames.toArray() {
    val callableClass = poolClass(asm.pool, callableName)
    val callableCtor  = poolMethodref(asm.pool, callableName, "<init>", "()V")
    val forkDesc = "(Ljava/util/concurrent/Callable;)Ljava/util/concurrent/StructuredTaskScope$Subtask;"
    val forkRef  = poolMethodref(asm.pool, scopeClass, "fork", forkDesc)

    emitAload(asm, scopeSlot)
    emitNew(asm, callableClass)
    emitDup(asm)
    emitInvokespecial(asm, callableCtor)
    emitInvokevirtual(asm, forkRef)
    emitAstore(asm, taskSlot)
    taskSlot = taskSlot + 1
  }

  // join() and throwIfFailed()
  val joinRef = poolMethodref(asm.pool, scopeClass, "join", "()Ljava/util/concurrent/StructuredTaskScope;")
  val throwRef = poolMethodref(asm.pool, scopeClass, "throwIfFailed", "()V")
  emitAload(asm, scopeSlot)
  emitInvokevirtual(asm, joinRef)
  emitPop(asm)
  emitAload(asm, scopeSlot)
  emitInvokevirtual(asm, throwRef)
}

// ── B121: lowerFuncWithContract (inline requires/ensures bytecode) ────────────

pub record LContract {
  requiresInsns: List[LInsn]   // pushes Bool (1=ok, 0=violated); evaluated at entry
  ensuresInsns:  List[LInsn]   // same, evaluated before return
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
    flags     = f.flags,
    name      = f.name,
    params    = f.params,
    ret       = f.ret,
    insns     = wInsns,
    maxStack  = f.maxStack + 4,  // +4 for new AssertionError + dup + ldc + invokespecial
    maxLocals = f.maxLocals + extraLocals
  )
  lowerFunc(wFunc, pool)
}

// ── B122: lowerDeriveEquality (@derive(Equals) + @derive(Hash)) ──────────────

pub record LRecordWithDerives {
  className:  String
  fields:     List[LField]
  deriveEq:   Bool
  deriveHash: Bool
}

/// Lower a record with `@derive(Equals)` and/or `@derive(Hash)`.
/// Emits `equals(Object): boolean` with field-by-field comparison
/// and `hashCode(): int` with a prime-multiply accumulator.
pub func lowerDeriveEquality(d: in LRecordWithDerives, pool: in Pool): ClassFile {
  // First build the base record
  val r = LRecord(
    className = d.className,
    fields    = d.fields,
    methods   = newList()
  )
  val cf = lowerRecord(r, pool)

  val extraMethods: List[MethodInfo] = newList()

  if d.deriveEq {
    // equals(Object other): boolean
    // Build as LInsn list so lowerFuncForClass generates a correct StackMapTable.
    val eqInsns: List[LInsn] = newList()

    // Pre-initialize slot 2 (the cast result) so StackMapTable frames at early
    // branch targets (before slot 2 is assigned) declare it as live.
    eqInsns.add(LAconstNull)
    eqInsns.add(LAstoreAs(slot = 2, className = d.className))

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
    eqInsns.add(LInstanceof(className = d.className))
    eqInsns.add(LIfne(label = "eq_cast"))
    eqInsns.add(LIconst(v = 0))
    eqInsns.add(LIreturn)
    eqInsns.add(LLabel(name = "eq_cast"))

    // <className> o = (<className>) other; stored in slot 2
    eqInsns.add(LAload(slot = 1))
    eqInsns.add(LCheckcast(className = d.className))
    eqInsns.add(LAstoreAs(slot = 2, className = d.className))

    // Compare each field; return false on mismatch
    for fld in d.fields.toArray() {
      val skipLabel = "eq_skip_" + fld.name
      eqInsns.add(LAload(slot = 0))
      eqInsns.add(LGetfield(owner = d.className, name = fld.name, t = fld.fieldType))
      eqInsns.add(LAload(slot = 2))
      eqInsns.add(LGetfield(owner = d.className, name = fld.name, t = fld.fieldType))
      match fld.fieldType {
        case JInt     -> eqInsns.add(LIfIcmpeq(label = skipLabel))
        case JBoolean -> eqInsns.add(LIfIcmpeq(label = skipLabel))
        case JByte    -> eqInsns.add(LIfIcmpeq(label = skipLabel))
        case JChar    -> eqInsns.add(LIfIcmpeq(label = skipLabel))
        case JShort   -> eqInsns.add(LIfIcmpeq(label = skipLabel))
        case _        -> eqInsns.add(LIfAcmpeq(label = skipLabel))
      }
      eqInsns.add(LIconst(v = 0))
      eqInsns.add(LIreturn)
      eqInsns.add(LLabel(name = skipLabel))
    }
    eqInsns.add(LIconst(v = 1))
    eqInsns.add(LIreturn)

    val eqPs: List[JvmType] = newList()
    eqPs.add(JRef(className = "java/lang/Object"))
    val eqFunc = LFunc(
      flags     = ACC_PUBLIC,
      name      = "equals",
      params    = eqPs,
      ret       = JBoolean,
      insns     = eqInsns,
      maxStack  = 4,
      maxLocals = 3
    )
    extraMethods.add(lowerFuncForClass(eqFunc, d.className, pool))
  }

  if d.deriveHash {
    // hashCode(): int  — hash = 31 * hash + field_hash for each field
    val hashAsm = newAssembler(pool)
    lowerInsn(LIconst(v = 1), hashAsm)     // hash = 1
    lowerInsn(LIstore(slot = 1), hashAsm)

    for fld in d.fields.toArray() {
      lowerInsn(LIconst(v = 31), hashAsm)
      lowerInsn(LIload(slot = 1), hashAsm)
      lowerInsn(LImul, hashAsm)
      lowerInsn(LAload(slot = 0), hashAsm)
      lowerInsn(LGetfield(owner = d.className, name = fld.name, t = fld.fieldType), hashAsm)
      match fld.fieldType {
        case JInt     -> ()
        case JBoolean -> ()
        case JByte    -> ()
        case JChar    -> ()
        case JShort   -> ()
        case _        -> {
          // For reference fields, call .hashCode()
          val hcPs: List[JvmType] = newList()
          lowerInsn(LInvokevirtual(owner = "java/lang/Object", name = "hashCode", params = hcPs, ret = JInt), hashAsm)
        }
      }
      lowerInsn(LIadd, hashAsm)
      lowerInsn(LIstore(slot = 1), hashAsm)
    }
    lowerInsn(LIload(slot = 1), hashAsm)
    lowerInsn(LIreturn, hashAsm)

    val hashPs: List[JvmType] = newList()
    val hashCode = assembleCode(hashAsm, 4, 2)
    val hashAttrs: List[Attribute] = newList()
    hashAttrs.add(hashCode)
    extraMethods.add(makeMethodInfo(ACC_PUBLIC, "hashCode", buildDescriptor(hashPs, JInt), hashAttrs))
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
    flags        = cf.flags,
    thisClass    = cf.thisClass,
    superClass   = cf.superClass,
    interfaces   = cf.interfaces,
    fields       = cf.fields,
    methods      = allMethods,
    attrs        = cf.attrs
  )
}

// ── B123: lowerDeriveOrd (@derive(Compare/Add/Sub) on distinct types) ─────────

pub record LDistinctWithDerives {
  wrapperClass:  String
  underlyingType: JvmType
  deriveCompare: Bool
  deriveAdd:     Bool
  deriveSub:     Bool
}

/// Lower a distinct type with optional @derive(Compare), @derive(Add), @derive(Sub).
/// Emits `compareTo(T): int`, `$add(T): T`, `$sub(T): T` by delegating to the
/// underlying primitive.
pub func lowerDeriveOrd(d: in LDistinctWithDerives, pool: in Pool): ClassFile {
  // Build base distinct type
  val base = LDistinctType(
    wrapperClass   = d.wrapperClass,
    underlyingType = d.underlyingType
  )
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
      case _     -> lowerInsn(LIadd, addAsm)
    }
    val wrapperPs: List[JvmType] = newList()
    wrapperPs.add(d.underlyingType)
    lowerInsn(LInvokespecial(owner = d.wrapperClass, name = "<init>", params = wrapperPs, ret = JVoid), addAsm)
    lowerInsn(LAreturn, addAsm)
    val addCode = assembleCode(addAsm, 6, 2)
    val addAttrs: List[Attribute] = newList()
    addAttrs.add(addCode)
    extraMethods.add(makeMethodInfo(ACC_PUBLIC, "$add", buildDescriptor(selfParam, JRef(className = d.wrapperClass)), addAttrs))
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
      case _     -> lowerInsn(LIsub, subAsm)
    }
    val wrapperPsSub: List[JvmType] = newList()
    wrapperPsSub.add(d.underlyingType)
    lowerInsn(LInvokespecial(owner = d.wrapperClass, name = "<init>", params = wrapperPsSub, ret = JVoid), subAsm)
    lowerInsn(LAreturn, subAsm)
    val subCode = assembleCode(subAsm, 6, 2)
    val subAttrs: List[Attribute] = newList()
    subAttrs.add(subCode)
    extraMethods.add(makeMethodInfo(ACC_PUBLIC, "$sub", buildDescriptor(selfParam, JRef(className = d.wrapperClass)), subAttrs))
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
    flags        = cf.flags,
    thisClass    = cf.thisClass,
    superClass   = cf.superClass,
    interfaces   = cf.interfaces,
    fields       = cf.fields,
    methods      = allMethods,
    attrs        = cf.attrs
  )
}

// ── B124: lowerPackage (top-level integration entry point) ────────────────────

pub union LPackageItem {
  case LPRecord(rec: LRecord)
  case LPSealedUnion(su: LSealedUnion)
  case LPEnum(en: LEnumType)
  case LPOpaqueType(ot: LOpaqueType)
  case LPDistinctType(dt: LDistinctType)
  case LPRangeType(rt: LRangeType)
  case LPExposedRecord(er: LExposedRecord)
  case LPProtected(pt: LProtected)
  case LPFuncs(funcsClass: String, fns: List[LFunc])
  // B126: a @test_module file compiled for the JVM target.
  // `className` is the JVM binary name (e.g. "math_tests").
  // `slots` carries per-test metadata; method bodies are stubs until B127+.
  case LPTestModule(className: String, slots: List[TestMethodSlot])
}

pub record LPackage {
  packageName: String
  items:       List[LPackageItem]
}

func lowerFuncsToClass(funcsClass: in String, fns: in List[LFunc], pool: in Pool): ClassFile {
  val methods: List[MethodInfo] = newList()
  for fn in fns.toArray() {
    methods.add(lowerFunc(fn, pool))
  }
  makeClassWithMethods(funcsClass, methods)
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
      case LPFuncs(funcsClass, fns) -> {
        result.add(lowerFuncsToClass(funcsClass, fns, pool))
      }
      case LPTestModule(className, slots) -> {
        // B126: emit the test-module class (annotated stubs) plus the
        // @LyricTest annotation class so both land in the same JAR.
        result.add(lowerTestModuleClass(className, slots, pool))
        result.add(lyricTestAnnotationClass(pool))
      }
    }
  }

  result
}
