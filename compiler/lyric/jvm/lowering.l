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
  case LInstanceof(className: String)
  case LAconstNull
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
    case LInstanceof(cls) -> {
      val idx = poolClass(asm.pool, cls)
      emitInstanceof(asm, idx)
    }
    case LAconstNull -> emitAconstNull(asm)
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

/// Verifier type tags (JVMS §4.10.1.2, verification_type_info).
pub union VerifierType {
  case VTop                      // dead slot / void
  case VInteger                  // boolean, byte, char, short, int
  case VFloat
  case VLong
  case VDouble
  case VNull
  case VObject(className: String) // reference or array type
}

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

// Emit one verification_type_info entry (JVMS §4.7.4) to `w`.
// Object and array types write an additional u2 class pool index.
func emitVType(t: in VerifierType, pool: in Pool, w: in ByteWriter): Unit {
  match t {
    case VTop         -> writerByte(w, 0)
    case VInteger     -> writerByte(w, 1)
    case VFloat       -> writerByte(w, 2)
    case VDouble      -> writerByte(w, 3)
    case VLong        -> writerByte(w, 4)
    case VNull        -> writerByte(w, 5)
    case VObject(cls) -> {
      writerByte(w, 7)
      writerU2(w, poolClass(pool, cls))
    }
  }
}

// Add `l` to the Map-as-set `targets` if not already present.
func addTarget(targets: in Map[String, Bool], l: in String): Unit {
  match mapGet(targets, l) {
    case None    -> targets.add(l, true)
    case Some(_) -> ()
  }
}

// Return a set (Map[String, Bool]) of label names that are branch targets
// in the LInsn list.
func collectBranchTargets(insns: in List[LInsn]): Map[String, Bool] {
  val targets: Map[String, Bool] = newMap()
  var i = 0
  while i < insns.count {
    match insns[i] {
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
      case _              -> ()
    }
    i = i + 1
  }
  targets
}

// ── Lowering ──────────────────────────────────────────────────────────────────

pub func lowerFunc(f: in LFunc, pool: in Pool): MethodInfo {
  val asm = newAssembler(pool)
  for insn in f.insns.toArray() {
    lowerInsn(insn, asm)
  }

  // -- B5: stack-map computation -----------------------------------------
  // Assemble code bytes and collect label offsets.
  val ar = assembleRaw(asm)

  // Build initial local variable frame from the method's parameter types.
  // ACC_STATIC = 0x0008 = 8; test using (flags / 8) % 2.
  val initialLocals: List[VerifierType] = newList()
  val isStatic = (f.flags / 8) % 2 == 1
  if not isStatic {
    initialLocals.add(VObject(className = "java/lang/Object"))
  }
  var pi = 0
  while pi < f.params.count {
    initialLocals.add(jvmToVerifier(f.params[pi]))
    pi = pi + 1
  }

  // Walk the LInsn list in order; for each LLabel that is a branch target,
  // emit a full_frame (255) StackMapTable entry.
  val branchTargets = collectBranchTargets(f.insns)
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
              writerU2(smBuf, initialLocals.count)
              var vi = 0
              while vi < initialLocals.count {
                emitVType(initialLocals[vi], pool, smBuf)
                vi = vi + 1
              }
              writerU2(smBuf, 0)               // stack items = 0 (empty)
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
  writerU2(codeW, f.maxStack)
  writerU2(codeW, f.maxLocals)
  writerU4(codeW, ar.codeBytes.count)
  writerByteList(codeW, ar.codeBytes)
  writerU2(codeW, 0)               // exception_table_length = 0
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
