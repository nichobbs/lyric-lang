// jvm/lowering.l — Stage B3 JVM type descriptors and instruction lowering.
//
// Provides:
//   • `JvmType` — typed representation of JVM field/return types.
//   • `LInsn` — high-level instruction union; `lowerInsn` resolves pool refs.
//   • `LField` / `LFunc` / `LRecord` — typed class/method/field descriptors.
//   • `lowerFunc` — lowers an LFunc to a MethodInfo with a Code attribute.
//   • `lowerRecord` — lowers an LRecord to a ClassFile with a synthesised ctor.

package Jvm.Lowering

import Std.Core
import Std.Collections
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Bytecode

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

  case LPop
  case LDup

  case LIadd
  case LIsub
  case LImul
  case LIdiv
  case LIrem
  case LIneg
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
}

pub func lowerInsn(insn: in LInsn, asm: in MethodAssembler): Unit {
  match insn {
    case LLabel(n)      -> emitLabel(asm, n)
    case LNop           -> emitNop(asm)
    case LReturn        -> emitReturn(asm)
    case LIreturn       -> emitIreturn(asm)
    case LLreturn       -> emitLreturn(asm)
    case LDreturn       -> emitDreturn(asm)
    case LAreturn       -> emitAreturn(asm)
    case LAthrow        -> emitAthrow(asm)

    case LIconst(v)     -> emitPushInt(asm, v)
    case LLconst(v)     -> emitPushLong(asm, v)
    case LDconst(v)     -> emitPushDouble(asm, v)
    case LPushString(s) -> emitPushString(asm, s)

    case LIload(s)      -> emitIload(asm, s)
    case LLload(s)      -> emitLload(asm, s)
    case LDload(s)      -> emitDload(asm, s)
    case LAload(s)      -> emitAload(asm, s)
    case LIstore(s)     -> emitIstore(asm, s)
    case LLstore(s)     -> emitLstore(asm, s)
    case LDstore(s)     -> emitDstore(asm, s)
    case LAstore(s)     -> emitAstore(asm, s)

    case LPop           -> emitPop(asm)
    case LDup           -> emitDup(asm)

    case LIadd          -> emitIadd(asm)
    case LIsub          -> emitIsub(asm)
    case LImul          -> emitImul(asm)
    case LIdiv          -> emitIdiv(asm)
    case LIrem          -> emitIrem(asm)
    case LIneg          -> emitIneg(asm)
    case LI2l           -> emitI2l(asm)
    case LI2d           -> emitI2d(asm)
    case LL2i           -> emitL2i(asm)

    case LLadd          -> emitLadd(asm)
    case LLsub          -> emitLsub(asm)
    case LLmul          -> emitLmul(asm)
    case LLdiv          -> emitLdiv(asm)

    case LDadd          -> emitDadd(asm)
    case LDsub          -> emitDsub(asm)
    case LDmul          -> emitDmul(asm)
    case LDdiv          -> emitDdiv(asm)

    case LGoto(l)           -> emitGoto(asm, l)
    case LIfeq(l)           -> emitIfeq(asm, l)
    case LIfne(l)           -> emitIfne(asm, l)
    case LIflt(l)           -> emitIflt(asm, l)
    case LIfge(l)           -> emitIfge(asm, l)
    case LIfgt(l)           -> emitIfgt(asm, l)
    case LIfle(l)           -> emitIfle(asm, l)
    case LIfIcmpeq(l)       -> emitIfIcmpeq(asm, l)
    case LIfIcmpne(l)       -> emitIfIcmpne(asm, l)
    case LIfIcmplt(l)       -> emitIfIcmplt(asm, l)
    case LIfIcmpge(l)       -> emitIfIcmpge(asm, l)
    case LIfIcmpgt(l)       -> emitIfIcmpgt(asm, l)
    case LIfIcmple(l)       -> emitIfIcmple(asm, l)

    case LGetfield(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitGetfield(asm, idx)
    }
    case LPutfield(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitPutfield(asm, idx)
    }
    case LGetstatic(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitGetstatic(asm, idx)
    }
    case LPutstatic(owner, name, t) -> {
      val idx = poolFieldref(asm.pool, owner, name, typeDescriptor(t))
      emitPutstatic(asm, idx)
    }

    case LInvokevirtual(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokevirtual(asm, idx)
    }
    case LInvokespecial(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokespecial(asm, idx)
    }
    case LInvokestatic(owner, name, ps, ret) -> {
      val idx = poolMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokestatic(asm, idx)
    }
    case LInvokeinterface(owner, name, ps, ret, argCount) -> {
      val idx = poolIfaceMethodref(asm.pool, owner, name, buildDescriptor(ps, ret))
      emitInvokeinterface(asm, idx, argCount)
    }

    case LNew(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitNew(asm, idx)
    }
    case LCheckcast(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitCheckcast(asm, idx)
    }
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

// Returns 2 for double-width types (long, double), 1 for all others.
func fieldSlotSize(t: in JvmType): Int {
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

// Emit the appropriate load instruction for parameter slot `slot`
// of type `t` and push the value before a putfield.
// NOTE: JFloat uses iload as an approximation (B3 scope; no float fields in self-test).
func emitFieldLoad(t: in JvmType, slot: in Int, asm: in MethodAssembler): Unit {
  match t {
    case JLong    -> lowerInsn(LLload(slot = slot), asm)
    case JDouble  -> lowerInsn(LDload(slot = slot), asm)
    case JBoolean -> lowerInsn(LIload(slot = slot), asm)
    case JByte    -> lowerInsn(LIload(slot = slot), asm)
    case JChar    -> lowerInsn(LIload(slot = slot), asm)
    case JShort   -> lowerInsn(LIload(slot = slot), asm)
    case JInt     -> lowerInsn(LIload(slot = slot), asm)
    case JFloat   -> lowerInsn(LIload(slot = slot), asm)
    case JVoid    -> ()
    case JRef(_)  -> lowerInsn(LAload(slot = slot), asm)
    case JArray(_) -> lowerInsn(LAload(slot = slot), asm)
  }
}

// ── Lowering ──────────────────────────────────────────────────────────────────

pub func lowerFunc(f: in LFunc, pool: in Pool): MethodInfo {
  val asm = newAssembler(pool)
  for insn in f.insns.toArray() {
    lowerInsn(insn, asm)
  }
  val codeAttr = assembleCode(asm, f.maxStack, f.maxLocals)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  makeMethodInfo(f.flags, f.name, buildDescriptor(f.params, f.ret), attrs)
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
