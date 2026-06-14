//! jvm/bytecode.l — JVM instruction emitters and two-pass method assembler.
//!
//! Provides:
//!   • Opcode constants (every JVM opcode, named after JVMS §6.5 mnemonics).
//!   • `MethodAssembler`: an opaque builder that accumulates `AsmInsn` values
//!     (a sealed union of all instruction forms) and resolves branch targets
//!     in two passes.
//!   • Individual instruction emitter functions (`emitNop`, `emitInvokevirtual`,
//!     etc.) that append to a `MethodAssembler`.
//!   • `assembleCode`: runs the two-pass label resolution and returns the
//!     finished Code attribute as a `List[Byte]` for use with `makeCodeAttr`.
//!
//! Branch-target design (two-pass assembler):
//!   Pass 1 — walk the instruction list computing each instruction's byte
//!             offset.  Label pseudo-instructions record their offset in a
//!             Map[String, Int].
//!   Pass 2 — emit actual bytes.  Branch instructions resolve their target
//!             label's offset from the map and compute the signed offset.
//!
//! Stage B1 scope: wide-form branches (goto_w, jsr_w) are NOT emitted;
//! branch distances are assumed to fit in i16 (±32 KB).  The B3 assembler
//! will add a relaxation pass for large methods.
//!
//! Local-variable slot conventions:
//!   Slot 0 = `this` for virtual methods (absent for static methods).
//!   Slots 1+ = parameters in declaration order, then temporaries.
//!
//! Stack-depth tracking:
//!   `MethodAssembler` tracks the running stack depth in `curStack` and the
//!   peak depth in `peakStack`.  `lowerInsn` calls `trackStack` after each
//!   instruction.  `assembleCodeInferred` uses `asm.peakStack` automatically.
package Jvm.Bytecode

import Std.Core
import Std.Collections
import Jvm.Kernel
import Jvm.Classfile

// ── Opcode constants (JVMS §6.5) ─────────────────────────────────────────────
// Named after the JVMS mnemonic; prefix OP_ to avoid clashing with keywords.
pub val OP_NOP: Int = 0x00

pub val OP_ACONST_NULL: Int = 0x01

pub val OP_ICONST_M1: Int = 0x02

pub val OP_ICONST_0: Int = 0x03

pub val OP_ICONST_1: Int = 0x04

pub val OP_ICONST_2: Int = 0x05

pub val OP_ICONST_3: Int = 0x06

pub val OP_ICONST_4: Int = 0x07

pub val OP_ICONST_5: Int = 0x08

pub val OP_LCONST_0: Int = 0x09

pub val OP_LCONST_1: Int = 0x0A

pub val OP_FCONST_0: Int = 0x0B

pub val OP_FCONST_1: Int = 0x0C

pub val OP_FCONST_2: Int = 0x0D

pub val OP_DCONST_0: Int = 0x0E

pub val OP_DCONST_1: Int = 0x0F

pub val OP_BIPUSH: Int = 0x10

pub val OP_SIPUSH: Int = 0x11

pub val OP_LDC: Int = 0x12

pub val OP_LDC_W: Int = 0x13

pub val OP_LDC2_W: Int = 0x14

pub val OP_ILOAD: Int = 0x15

pub val OP_LLOAD: Int = 0x16

pub val OP_FLOAD: Int = 0x17

pub val OP_DLOAD: Int = 0x18

pub val OP_ALOAD: Int = 0x19

pub val OP_ILOAD_0: Int = 0x1A

pub val OP_ILOAD_1: Int = 0x1B

pub val OP_ILOAD_2: Int = 0x1C

pub val OP_ILOAD_3: Int = 0x1D

pub val OP_LLOAD_0: Int = 0x1E

pub val OP_LLOAD_1: Int = 0x1F

pub val OP_LLOAD_2: Int = 0x20

pub val OP_LLOAD_3: Int = 0x21

pub val OP_FLOAD_0: Int = 0x22

pub val OP_FLOAD_1: Int = 0x23

pub val OP_FLOAD_2: Int = 0x24

pub val OP_FLOAD_3: Int = 0x25

pub val OP_DLOAD_0: Int = 0x26

pub val OP_DLOAD_1: Int = 0x27

pub val OP_DLOAD_2: Int = 0x28

pub val OP_DLOAD_3: Int = 0x29

pub val OP_ALOAD_0: Int = 0x2A

pub val OP_ALOAD_1: Int = 0x2B

pub val OP_ALOAD_2: Int = 0x2C

pub val OP_ALOAD_3: Int = 0x2D

pub val OP_IALOAD: Int = 0x2E

pub val OP_LALOAD: Int = 0x2F

pub val OP_FALOAD: Int = 0x30

pub val OP_DALOAD: Int = 0x31

pub val OP_AALOAD: Int = 0x32

pub val OP_BALOAD: Int = 0x33

pub val OP_CALOAD: Int = 0x34

pub val OP_SALOAD: Int = 0x35

pub val OP_ISTORE: Int = 0x36

pub val OP_LSTORE: Int = 0x37

pub val OP_FSTORE: Int = 0x38

pub val OP_DSTORE: Int = 0x39

pub val OP_ASTORE: Int = 0x3A

pub val OP_ISTORE_0: Int = 0x3B

pub val OP_ISTORE_1: Int = 0x3C

pub val OP_ISTORE_2: Int = 0x3D

pub val OP_ISTORE_3: Int = 0x3E

pub val OP_LSTORE_0: Int = 0x3F

pub val OP_LSTORE_1: Int = 0x40

pub val OP_LSTORE_2: Int = 0x41

pub val OP_LSTORE_3: Int = 0x42

pub val OP_FSTORE_0: Int = 0x43

pub val OP_FSTORE_1: Int = 0x44

pub val OP_FSTORE_2: Int = 0x45

pub val OP_FSTORE_3: Int = 0x46

pub val OP_DSTORE_0: Int = 0x47

pub val OP_DSTORE_1: Int = 0x48

pub val OP_DSTORE_2: Int = 0x49

pub val OP_DSTORE_3: Int = 0x4A

pub val OP_ASTORE_0: Int = 0x4B

pub val OP_ASTORE_1: Int = 0x4C

pub val OP_ASTORE_2: Int = 0x4D

pub val OP_ASTORE_3: Int = 0x4E

pub val OP_IASTORE: Int = 0x4F

pub val OP_LASTORE: Int = 0x50

pub val OP_FASTORE: Int = 0x51

pub val OP_DASTORE: Int = 0x52

pub val OP_AASTORE: Int = 0x53

pub val OP_BASTORE: Int = 0x54

pub val OP_CASTORE: Int = 0x55

pub val OP_SASTORE: Int = 0x56

pub val OP_POP: Int = 0x57

pub val OP_POP2: Int = 0x58

pub val OP_DUP: Int = 0x59

pub val OP_DUP_X1: Int = 0x5A

pub val OP_DUP_X2: Int = 0x5B

pub val OP_DUP2: Int = 0x5C

pub val OP_DUP2_X1: Int = 0x5D

pub val OP_DUP2_X2: Int = 0x5E

pub val OP_SWAP: Int = 0x5F

pub val OP_IADD: Int = 0x60

pub val OP_LADD: Int = 0x61

pub val OP_FADD: Int = 0x62

pub val OP_DADD: Int = 0x63

pub val OP_ISUB: Int = 0x64

pub val OP_LSUB: Int = 0x65

pub val OP_FSUB: Int = 0x66

pub val OP_DSUB: Int = 0x67

pub val OP_IMUL: Int = 0x68

pub val OP_LMUL: Int = 0x69

pub val OP_FMUL: Int = 0x6A

pub val OP_DMUL: Int = 0x6B

pub val OP_IDIV: Int = 0x6C

pub val OP_LDIV: Int = 0x6D

pub val OP_FDIV: Int = 0x6E

pub val OP_DDIV: Int = 0x6F

pub val OP_IREM: Int = 0x70

pub val OP_LREM: Int = 0x71

pub val OP_FREM: Int = 0x72

pub val OP_DREM: Int = 0x73

pub val OP_INEG: Int = 0x74

pub val OP_LNEG: Int = 0x75

pub val OP_FNEG: Int = 0x76

pub val OP_DNEG: Int = 0x77

pub val OP_ISHL: Int = 0x78

pub val OP_LSHL: Int = 0x79

pub val OP_ISHR: Int = 0x7A

pub val OP_LSHR: Int = 0x7B

pub val OP_IUSHR: Int = 0x7C

pub val OP_LUSHR: Int = 0x7D

pub val OP_IAND: Int = 0x7E

pub val OP_LAND: Int = 0x7F

pub val OP_IOR: Int = 0x80

pub val OP_LOR: Int = 0x81

pub val OP_IXOR: Int = 0x82

pub val OP_LXOR: Int = 0x83

pub val OP_IINC: Int = 0x84

pub val OP_I2L: Int = 0x85

pub val OP_I2F: Int = 0x86

pub val OP_I2D: Int = 0x87

pub val OP_L2I: Int = 0x88

pub val OP_L2F: Int = 0x89

pub val OP_L2D: Int = 0x8A

pub val OP_F2I: Int = 0x8B

pub val OP_F2L: Int = 0x8C

pub val OP_F2D: Int = 0x8D

pub val OP_D2I: Int = 0x8E

pub val OP_D2L: Int = 0x8F

pub val OP_D2F: Int = 0x90

pub val OP_I2B: Int = 0x91

pub val OP_I2C: Int = 0x92

pub val OP_I2S: Int = 0x93

pub val OP_LCMP: Int = 0x94

pub val OP_FCMPL: Int = 0x95

pub val OP_FCMPG: Int = 0x96

pub val OP_DCMPL: Int = 0x97

pub val OP_DCMPG: Int = 0x98

pub val OP_IFEQ: Int = 0x99

pub val OP_IFNE: Int = 0x9A

pub val OP_IFLT: Int = 0x9B

pub val OP_IFGE: Int = 0x9C

pub val OP_IFGT: Int = 0x9D

pub val OP_IFLE: Int = 0x9E

pub val OP_IF_ICMPEQ: Int = 0x9F

pub val OP_IF_ICMPNE: Int = 0xA0

pub val OP_IF_ICMPLT: Int = 0xA1

pub val OP_IF_ICMPGE: Int = 0xA2

pub val OP_IF_ICMPGT: Int = 0xA3

pub val OP_IF_ICMPLE: Int = 0xA4

pub val OP_IF_ACMPEQ: Int = 0xA5

pub val OP_IF_ACMPNE: Int = 0xA6

pub val OP_GOTO: Int = 0xA7

pub val OP_JSR: Int = 0xA8

pub val OP_RET: Int = 0xA9

pub val OP_TABLESWITCH: Int = 0xAA

pub val OP_LOOKUPSWITCH: Int = 0xAB

pub val OP_IRETURN: Int = 0xAC

pub val OP_LRETURN: Int = 0xAD

pub val OP_FRETURN: Int = 0xAE

pub val OP_DRETURN: Int = 0xAF

pub val OP_ARETURN: Int = 0xB0

pub val OP_RETURN: Int = 0xB1

pub val OP_GETSTATIC: Int = 0xB2

pub val OP_PUTSTATIC: Int = 0xB3

pub val OP_GETFIELD: Int = 0xB4

pub val OP_PUTFIELD: Int = 0xB5

pub val OP_INVOKEVIRTUAL: Int = 0xB6

pub val OP_INVOKESPECIAL: Int = 0xB7

pub val OP_INVOKESTATIC: Int = 0xB8

pub val OP_INVOKEINTERFACE: Int = 0xB9

pub val OP_INVOKEDYNAMIC: Int = 0xBA

pub val OP_NEW: Int = 0xBB

pub val OP_NEWARRAY: Int = 0xBC

pub val OP_ANEWARRAY: Int = 0xBD

pub val OP_ARRAYLENGTH: Int = 0xBE

pub val OP_ATHROW: Int = 0xBF

pub val OP_CHECKCAST: Int = 0xC0

pub val OP_INSTANCEOF: Int = 0xC1

pub val OP_MONITORENTER: Int = 0xC2

pub val OP_MONITOREXIT: Int = 0xC3

pub val OP_WIDE: Int = 0xC4

pub val OP_MULTIANEWARRAY: Int = 0xC5

pub val OP_IFNULL: Int = 0xC6

pub val OP_IFNONNULL: Int = 0xC7

pub val OP_GOTO_W: Int = 0xC8

pub val OP_JSR_W: Int = 0xC9

// newarray type codes (JVMS §6.5 newarray)
pub val T_BOOLEAN: Int = 4

pub val T_CHAR: Int = 5

pub val T_FLOAT: Int = 6

pub val T_DOUBLE: Int = 7

pub val T_BYTE: Int = 8

pub val T_SHORT: Int = 9

pub val T_INT: Int = 10

pub val T_LONG: Int = 11

/// One key→label entry in a lookupswitch table.
pub record SwitchPair {
  key: Int
  label: String
}

// ── Instruction union ─────────────────────────────────────────────────────────
// Each variant carries precisely the operands the JVM opcode needs.
// Labels are strings (unique within a method); branch instructions
// target a label name rather than a raw offset (resolved in pass 2).
pub union AsmInsn {
  // Pseudo-instruction: defines a label at the current offset.
  case Label(name: String)

  // Nullary opcodes (no operands).
  case Nullary(op: Int)

  // Opcodes with a single u1 immediate (e.g. bipush, newarray).
  case U1(op: Int, imm: Int)

  // Opcodes with a single u2 immediate (e.g. sipush, ldc_w).
  case U2(op: Int, imm: Int)

  // Opcodes with a u1 local-variable index (iload, astore, …).
  case LocalU1(op: Int, slot: Int)

  // Opcodes with a u2 local-variable index (wide form).
  case LocalU2Wide(op: Int, slot: Int)

  // iinc: u1 index + i8 constant (or wide: u2 index + i16 constant).
  case Iinc(slot: Int, delta: Int)

  // Field/method reference: opcode + u2 pool index.
  case Ref(op: Int, classIdx: Int, natIdx: Int)

  // invokeinterface: opcode + u2 index + u1 count + u1 zero.
  case InvokeInterface(classIdx: Int, natIdx: Int, argCount: Int)

  // invokedynamic: u2 index + u2 zero.
  case InvokeDynamic(dynIdx: Int)

  // Branch instruction: opcode + label name (resolved to i16 offset in
  // pass 2).  Named `BranchInsn` rather than `Branch` to avoid colliding
  // with `Lyric.Manifest.GitRef.Branch(name: String)` /
  // `Lyric.GitDep.GitRef.Branch(name: String)` in the F# bootstrap
  // emitter's import resolver when both packages share a compile scope
  // (see `lyric-compiler/lyric/emitter.l`'s comment about the in-process
  // MSIL path).
  case BranchInsn(op: Int, label: String)

  // goto_w: label name (resolved to i32 offset).
  case GotoW(label: String)

  // new / checkcast / instanceof: u2 class pool index.
  case ClassRef(op: Int, classIdx: Int)

  // newarray: u1 element type code.
  case NewArray(typeCode: Int)

  // anewarray / multianewarray.
  case ANewArray(classIdx: Int)
  case MultiANewArray(classIdx: Int, dims: Int)

  // ldc (u1 pool index ≤ 255) vs ldc_w (u2 index).
  case Ldc(poolIdx: Int)
  case LdcW(poolIdx: Int)
  case Ldc2W(poolIdx: Int)   // long / double constants

  // tableswitch: size is position-dependent (alignment padding).
  // swIdx indexes into asm.swDefaults and asm.swTableLabels/swTableOff.
  // Do NOT rely on insnSize for this variant.
  case TableSwitch(low: Int, high: Int, nCases: Int, swIdx: Int)

  // lookupswitch: size is position-dependent (alignment padding).
  // swIdx indexes into asm.swDefaults, asm.swLookupKeys, asm.swLookupLabels, asm.swLookupOff.
  case LookupSwitch(nPairs: Int, swIdx: Int)
}

// ── MethodAssembler ───────────────────────────────────────────────────────────
/// Builder that accumulates AsmInsn values for a single method body.
/// Call `emitXxx` functions to append instructions, then `assembleCode`
/// to run the two-pass assembler and produce a Code attribute.
///
/// Switch table data is stored in parallel lists here rather than in
/// the AsmInsn union, because non-generic union case fields of List[T]
/// are erased to Object by the D035 erasure path and cannot be accessed.
/// A pending exception-table entry in the assembler.  Label names are
/// resolved to PCs at assembly time by `assembleCode`.
/// `catchType` is a CONSTANT_Class constant-pool index, or 0 for catch-all.
pub record AsmExnHandler {

  startLabel: String
  endLabel: String
  handlerLabel: String
  catchType: Int
}

pub record MethodAssembler {
  insns: List[AsmInsn]
  pool: Pool          // shared constant pool
  swDefaults: List[String]  // default label for each switch (indexed by swIdx)
  swTableLabels: List[String]  // all tableswitch case labels (flat)
  swTableOff: List[Int]     // start index in swTableLabels for each tableswitch
  swLookupKeys: List[Int]     // all lookupswitch keys (flat)
  swLookupLabels: List[String]  // all lookupswitch labels (flat)
  swLookupOff: List[Int]     // start index for each lookupswitch in swLookupKeys/Labels
  curStack: Int           // current stack depth during lowerInsn calls
  peakStack: Int           // maximum stack depth seen so far
  exnHandlers: List[AsmExnHandler]   // exception-table entries accumulated by emitters
}

/// Construct a fresh assembler sharing `pool`.
pub func newAssembler(pool: in Pool): MethodAssembler {
  MethodAssembler(
    insns = newList(),
    pool = pool,
    swDefaults = newList(),
    swTableLabels = newList(),
    swTableOff = newList(),
    swLookupKeys = newList(),
    swLookupLabels = newList(),
    swLookupOff = newList(),
    curStack = 0,
    peakStack = 0,
    exnHandlers = newList()
  )
}

/// Register an exception-table entry to be emitted when the assembler is
/// assembled.  `catchType` is a CONSTANT_Class pool index (0 = catch-all).
pub func addExceptionHandler(
  asm: in MethodAssembler,
  startLabel: in String,
  endLabel: in String,
  handlerLabel: in String,
  catchType: in Int,
): Unit {
  asm.exnHandlers.add(
    AsmExnHandler(startLabel = startLabel, endLabel = endLabel, handlerLabel = handlerLabel, catchType = catchType)
  )
}

/// Update the running stack depth by `delta` and record a new peak if needed.
pub func trackStack(asm: in MethodAssembler, delta: in Int): Unit {
  asm.curStack = asm.curStack + delta
  if asm.curStack > asm.peakStack {
    asm.peakStack = asm.curStack
  }
}

/// Reset the current stack depth to 0 (used at every label / branch target).
pub func resetStack(asm: in MethodAssembler): Unit {
  asm.curStack = 0
}

/// Append a raw `AsmInsn` to the assembler.  Most callers use the typed
/// `emitXxx` helpers below, which construct the right variant.
pub func emitInsn(asm: in MethodAssembler, insn: in AsmInsn): Unit {
  asm.insns.add(insn)
}

// ── Instruction size helpers (pass 1) ────────────────────────────────────────
// Returns the number of bytes the instruction occupies in the bytecode stream.
func insnSize(insn: in AsmInsn): Int {
  match insn {
    case Label(_) -> 0       // pseudo; contributes nothing
    case Nullary(_) -> 1
    case U1(_, _) -> 2       // op + u1
    case U2(_, _) -> 3       // op + u2
    case LocalU1(_, _) -> 2
    case LocalU2Wide(_, _) -> 4       // wide + op + u2
    case Iinc(slot, delta) -> if slot <= 255 and delta >= -128 and delta <= 127 then 3   // op + u1 + i8
    else 6                                                    // wide + op + u2 + i16
    case Ref(_, _, _) -> 3       // op + u2 (pool index is a single u2
    //   computed from classIdx; see emitInsn2)
    case InvokeInterface(_, _, _) -> 5      // op + u2 + u1 count + u1 zero
    case InvokeDynamic(_) -> 5       // op + u2 + u2 zero
    case BranchInsn(_, _) -> 3       // op + i16
    case GotoW(_) -> 5       // goto_w + i32
    case ClassRef(_, _) -> 3       // op + u2
    case NewArray(_) -> 2       // op + u1
    case ANewArray(_) -> 3
    case MultiANewArray(_, _) -> 4
    case Ldc(_) -> 2       // op + u1 index
    case LdcW(_) -> 3
    case Ldc2W(_) -> 3
    // position-dependent; handled specially in buildLabelMap / emitAllInsns
    case TableSwitch(_, _, _, _) -> 0  // (low, high, nCases, swIdx)
    case LookupSwitch(_, _) -> 0  // (nPairs, swIdx)
  }
}

// ── Two-pass assembler ────────────────────────────────────────────────────────
// Pass 1: walk the instruction list and build a label→offset map.
// Alignment padding bytes added before tableswitch / lookupswitch operands.
// The opcode itself is at `opcodeOffset`; the padding follows the opcode byte.
func switchPadding(opcodeOffset: in Int): Int {
  (4 - ((opcodeOffset + 1) % 4)) % 4
}

func buildLabelMap(asm: in MethodAssembler): Map[String, Int] {
  val labels: Map[String, Int] = newMap()
  var offset = 0
  for insn in asm.insns.toArray() {
    match insn {
      case Label(name) -> labels.add(name, offset)
      case TableSwitch(_, _, nCases, _) -> {
        val pad = switchPadding(offset)
        offset = offset + 1 + pad + 4 + 4 + 4 + 4 * nCases
      }
      case LookupSwitch(nPairs, _) -> {
        val pad = switchPadding(offset)
        offset = offset + 1 + pad + 4 + 4 + 8 * nPairs
      }
      case _ -> {
        offset = offset + insnSize(insn)
      }
    }
  }
  labels
}

// Encode a Ref instruction.  Pool indices are stored separately as
// classIdx / natIdx in the union; the actual pool ref is classIdx itself
// when already a Fieldref/Methodref/InterfaceMethodref index.
// Convention: Ref(op, poolRef, 0) where poolRef is the direct pool index.
func emitRef(buf: in ByteWriter, op: in Int, poolRef: in Int): Unit {
  writerByte(buf, op)
  writerU2(buf, poolRef)
}

// Pass 2: emit actual bytes, resolving branches.
func emitAllInsns(asm: in MethodAssembler, labels: in Map[String, Int], buf: in ByteWriter): Unit {
  var offset = 0
  for insn in asm.insns.toArray() {
    match insn {
      case Label(_) -> ()  // no bytes emitted

      case Nullary(op) -> {
        writerByte(buf, op)
        offset = offset + 1
      }

      case U1(op, imm) -> {
        writerByte(buf, op)
        writerByte(buf, imm)
        offset = offset + 2
      }

      case U2(op, imm) -> {
        writerByte(buf, op)
        writerU2(buf, imm)
        offset = offset + 3
      }

      case LocalU1(op, slot) -> {
        writerByte(buf, op)
        writerByte(buf, slot)
        offset = offset + 2
      }

      case LocalU2Wide(op, slot) -> {
        writerByte(buf, OP_WIDE)
        writerByte(buf, op)
        writerU2(buf, slot)
        offset = offset + 4
      }

      case Iinc(slot, delta) -> {
        if slot <= 255 and delta >= -128 and delta <= 127 {
          writerByte(buf, OP_IINC)
          writerByte(buf, slot)
          writerByte(buf, delta)      // signed byte, but writerByte masks low 8 bits
          offset = offset + 3
        } else {
          writerByte(buf, OP_WIDE)
          writerByte(buf, OP_IINC)
          writerU2(buf, slot)
          writerU2(buf, delta)        // signed i16 as u2
          offset = offset + 6
        }
      }

      case Ref(op, poolRef, _) -> {
        writerByte(buf, op)
        writerU2(buf, poolRef)
        offset = offset + 3
      }

      case InvokeInterface(poolRef, _, count) -> {
        writerByte(buf, OP_INVOKEINTERFACE)
        writerU2(buf, poolRef)
        writerByte(buf, count)
        writerByte(buf, 0)
        offset = offset + 5
      }

      case InvokeDynamic(dynIdx) -> {
        writerByte(buf, OP_INVOKEDYNAMIC)
        writerU2(buf, dynIdx)
        writerU2(buf, 0)
        offset = offset + 5
      }

      case BranchInsn(op, label) -> {
        val target = mapGet(labels, label)
        val resolved = match target { case Some(t) -> t; case None -> panic(format1("undefined label: {0}", label)) }
        val delta = resolved - offset
        writerByte(buf, op)
        writerU2(buf, delta)    // signed i16 written as u2 (two's complement)
        offset = offset + 3
      }

      case GotoW(label) -> {
        val target = mapGet(labels, label)
        val resolved = match target { case Some(t) -> t; case None -> panic(format1("undefined label: {0}", label)) }
        val delta = resolved - offset
        writerByte(buf, OP_GOTO_W)
        writerU4(buf, delta)
        offset = offset + 5
      }

      case ClassRef(op, classIdx) -> {
        writerByte(buf, op)
        writerU2(buf, classIdx)
        offset = offset + 3
      }

      case NewArray(typeCode) -> {
        writerByte(buf, OP_NEWARRAY)
        writerByte(buf, typeCode)
        offset = offset + 2
      }

      case ANewArray(classIdx) -> {
        writerByte(buf, OP_ANEWARRAY)
        writerU2(buf, classIdx)
        offset = offset + 3
      }

      case MultiANewArray(classIdx, dims) -> {
        writerByte(buf, OP_MULTIANEWARRAY)
        writerU2(buf, classIdx)
        writerByte(buf, dims)
        offset = offset + 4
      }

      case Ldc(poolIdx) -> {
        writerByte(buf, OP_LDC)
        writerByte(buf, poolIdx)
        offset = offset + 2
      }

      case LdcW(poolIdx) -> {
        writerByte(buf, OP_LDC_W)
        writerU2(buf, poolIdx)
        offset = offset + 3
      }

      case Ldc2W(poolIdx) -> {
        writerByte(buf, OP_LDC2_W)
        writerU2(buf, poolIdx)
        offset = offset + 3
      }

      case TableSwitch(low, high, nCases, swIdx) -> {
        val pad = switchPadding(offset)
        val defaultLabel = asm.swDefaults[swIdx]
        val labelOff = asm.swTableOff[swIdx]
        writerByte(buf, OP_TABLESWITCH)
        var p = 0
        while p < pad {
          writerByte(buf, 0)
          p = p + 1
        }
        val defOff = match mapGet(labels, defaultLabel) {
          case Some(t) -> t - offset
          case None -> panic(format1("tableswitch: undefined default label '{0}'", defaultLabel))
        }
        writerU4(buf, defOff)
        writerU4(buf, low)
        writerU4(buf, high)
        var ci = 0
        while ci < nCases {
          val lbl = asm.swTableLabels[labelOff + ci]
          val cOff = match mapGet(labels, lbl) {
            case Some(t) -> t - offset
            case None -> panic(format1("tableswitch: undefined case label '{0}'", lbl))
          }
          writerU4(buf, cOff)
          ci = ci + 1
        }
        offset = offset + 1 + pad + 4 + 4 + 4 + 4 * nCases
      }

      case LookupSwitch(nPairs, swIdx) -> {
        val pad = switchPadding(offset)
        val defaultLabel = asm.swDefaults[swIdx]
        val dataOff = asm.swLookupOff[swIdx]
        writerByte(buf, OP_LOOKUPSWITCH)
        var p = 0
        while p < pad {
          writerByte(buf, 0)
          p = p + 1
        }
        val defOff = match mapGet(labels, defaultLabel) {
          case Some(t) -> t - offset
          case None -> panic(format1("lookupswitch: undefined default label '{0}'", defaultLabel))
        }
        writerU4(buf, defOff)
        writerU4(buf, nPairs)
        var pi = 0
        while pi < nPairs {
          val key = asm.swLookupKeys[dataOff + pi]
          val lbl = asm.swLookupLabels[dataOff + pi]
          val cOff = match mapGet(labels, lbl) {
            case Some(t) -> t - offset
            case None -> panic(format1("lookupswitch: undefined case label '{0}'", lbl))
          }
          writerU4(buf, key)
          writerU4(buf, cOff)
          pi = pi + 1
        }
        offset = offset + 1 + pad + 4 + 4 + 8 * nPairs
      }
    }
  }
}

// ── Public assembly entry point ───────────────────────────────────────────────
/// True for instructions that transfer control unconditionally and so do not
/// fall through: the instruction *after* one of these begins a new basic block.
func isTransferInsn(insn: in AsmInsn): Bool {
  match insn {
    case Nullary(op) -> op == OP_IRETURN or op == OP_LRETURN or op == OP_FRETURN or op == OP_DRETURN or op == OP_ARETURN or op == OP_RETURN or op == OP_ATHROW
    case BranchInsn(op, _) -> op == OP_GOTO
    case GotoW(_) -> true
    case _ -> false
  }
}

/// Byte offsets of instructions that begin a new basic block by following an
/// unconditional control transfer (goto / goto_w / *return / athrow / switch).
/// The JVM verifier requires a StackMapTable frame at every such block start —
/// even for unreachable code, e.g. the `goto` a match/if arm emits right after
/// a `panic`'s `athrow`.  Without a frame there the verifier rejects the method
/// with "Expecting a stack map frame".  Offsets are computed with the same
/// size/padding walk as `buildLabelMap` so they line up with `labelOffsets`.
func collectBlockStarts(asm: in MethodAssembler): List[Int] {
  val starts: List[Int] = newList()
  var offset = 0
  var prevTransfer = false
  for insn in asm.insns.toArray() {
    match insn {
      case Label(_) -> {
      }   // zero width; does not interrupt the transfer flag
      case TableSwitch(_, _, nCases, _) -> {
        if prevTransfer {
          starts.add(offset)
        }
        val pad = switchPadding(offset)
        // op + pad + default(4) + low(4) + high(4) + 4*nCases — must match
        // buildLabelMap exactly or every later offset (and block start) drifts.
        offset = offset + 1 + pad + 4 + 4 + 4 + 4 * nCases
        prevTransfer = true
      }
      case LookupSwitch(nPairs, _) -> {
        if prevTransfer {
          starts.add(offset)
        }
        val pad = switchPadding(offset)
        offset = offset + 1 + pad + 4 + 4 + 8 * nPairs
        prevTransfer = true
      }
      case _ -> {
        if prevTransfer {
          starts.add(offset)
        }
        prevTransfer = isTransferInsn(insn)
        offset = offset + insnSize(insn)
      }
    }
  }
  starts
}

/// Raw assembly result: code bytes + label-to-offset map.
/// Used by Jvm.Lowering (B5) to compute stack-map frames before
/// building the Code attribute.
pub record AssemblyResult {
  codeBytes: List[Byte]
  labelOffsets: Map[String, Int]
  blockStarts: List[Int]
}

/// Assemble the instruction list to bytes and return both the code bytes
/// and the label-offset map without building the Code attribute.
/// Used by lowerFunc (B5) for stack-map computation.
pub func assembleRaw(asm: in MethodAssembler): AssemblyResult {
  val labels = buildLabelMap(asm)
  val code = writerNew()
  emitAllInsns(asm, labels, code)
  AssemblyResult(codeBytes = writerToList(code), labelOffsets = labels, blockStarts = collectBlockStarts(asm))
}

/// Run the two-pass assembler over `asm` and return a finished
/// `Code` attribute.
///
/// `maxStack` must be supplied by the caller; stack depth analysis
/// (automatic max_stack computation) is a B4 extension.
///
/// `maxLocals` must include slot 0 (`this`) for virtual methods.
pub func assembleCode(asm: in MethodAssembler, maxStack: in Int, maxLocals: in Int): Attribute {
  val labels = buildLabelMap(asm)
  val code = writerNew()
  emitAllInsns(asm, labels, code)
  val bytes = writerToList(code)
  if asm.exnHandlers.count == 0 {
    makeCodeAttr(maxStack, maxLocals, bytes)
  } else {
    // Build Code attribute with N exception-table entries.
    val w = writerNew()
    writerU2(w, maxStack)
    writerU2(w, maxLocals)
    writerU4(w, bytes.count)
    writerByteList(w, bytes)
    writerU2(w, asm.exnHandlers.count)
    var hi = 0
    while hi < asm.exnHandlers.count {
      val h = asm.exnHandlers[hi]
      writerU2(w, resolveLbl(labels, h.startLabel))
      writerU2(w, resolveLbl(labels, h.endLabel))
      writerU2(w, resolveLbl(labels, h.handlerLabel))
      writerU2(w, h.catchType)
      hi = hi + 1
    }
    writerU2(w, 0)
    attrFromWriter("Code", w)
  }
}

/// Like `assembleCode` but uses `asm.peakStack` instead of a caller-supplied maxStack.
pub func assembleCodeInferred(asm: in MethodAssembler, maxLocals: in Int): Attribute {
  assembleCode(asm, asm.peakStack, maxLocals)
}

func resolveLbl(labels: in Map[String, Int], name: in String): Int {
  match mapGet(labels, name) {
    case Some(v) -> v
    case None -> 0
  }
}

/// Assemble with one exception-table entry (label names resolved to PCs).
pub func assembleCodeWith1Handler(
  asm: in MethodAssembler,
  maxStack: in Int,
  maxLocals: in Int,
  startLabel: in String,
  endLabel: in String,
  handlerLabel: in String,
  catchType: in Int,
): Attribute {
  val labels = buildLabelMap(asm)
  val code = writerNew()
  emitAllInsns(asm, labels, code)
  val sp = resolveLbl(labels, startLabel)
  val ep = resolveLbl(labels, endLabel)
  val hp = resolveLbl(labels, handlerLabel)
  makeCodeAttrWithHandler(maxStack, maxLocals, writerToList(code), sp, ep, hp, catchType)
}

/// Assemble with two exception-table entries (label names resolved to PCs).
pub func assembleCodeWith2Handlers(
  asm: in MethodAssembler,
  maxStack: in Int,
  maxLocals: in Int,
  startLabel1: in String,
  endLabel1: in String,
  handlerLabel1: in String,
  catchType1: in Int,
  startLabel2: in String,
  endLabel2: in String,
  handlerLabel2: in String,
  catchType2: in Int,
): Attribute {
  val labels = buildLabelMap(asm)
  val code = writerNew()
  emitAllInsns(asm, labels, code)
  val sp1 = resolveLbl(labels, startLabel1)
  val ep1 = resolveLbl(labels, endLabel1)
  val hp1 = resolveLbl(labels, handlerLabel1)
  val sp2 = resolveLbl(labels, startLabel2)
  val ep2 = resolveLbl(labels, endLabel2)
  val hp2 = resolveLbl(labels, handlerLabel2)
  makeCodeAttrWith2Handlers(
    maxStack,
    maxLocals,
    writerToList(code),
    sp1,
    ep1,
    hp1,
    catchType1,
    sp2,
    ep2,
    hp2,
    catchType2
  )
}

// ── B18: StackMapTable generation for manually-assembled bytecode ─────────────
//
// Java class files with major version >= 50 (Java 6+) require a StackMapTable
// attribute inside every Code attribute that has branch targets.  The helpers
// below allow manually-assembled methods (those not going through lowerFunc in
// Jvm.Lowering) to include proper stack-map frames so they run on modern JVMs
// without -noverify.
//
// Invariant assumed by this implementation: every branch target has an empty
// operand stack, and the local-variable frame at every branch target is the
// same (the `frameLocals` list passed to `assembleCodeWithFrames`).  Both
// invariants hold for straight-line methods with a single conditional branch,
// and for any method generated by lowerFunc.
/// Verification type tags used in StackMapTable entries (JVMS §4.10.1.2).
pub union VerifierType {
  case VTop                       // dead slot / void (tag 0)
  case VInteger                   // int, boolean, byte, char, short (tag 1)
  case VFloat                     // float (tag 2)
  case VDouble                    // double (tag 3)
  case VLong                      // long (tag 4)
  case VNull                      // null reference (tag 5)
  case VObject(className: String) // reference type or array (tag 7 + u2 class index)
}

pub func emitVerifierTypeBc(t: in VerifierType, pool: in Pool, w: in ByteWriter): Unit {
  match t {
    case VTop -> writerByte(w, 0)
    case VInteger -> writerByte(w, 1)
    case VFloat -> writerByte(w, 2)
    case VDouble -> writerByte(w, 3)
    case VLong -> writerByte(w, 4)
    case VNull -> writerByte(w, 5)
    case VObject(cls) -> {
      writerByte(w, 7)
      writerU2(w, poolClass(pool, cls))
    }
  }
}

func collectBranchLabels(asm: in MethodAssembler): Map[String, Bool] {
  val seen: Map[String, Bool] = newMap()
  var bi = 0
  while bi < asm.insns.count {
    match asm.insns[bi] {
      case BranchInsn(_, lbl) -> {
        match mapGet(seen, lbl) {
          case None -> seen.add(lbl, true)
          case Some(_) -> ()
        }
      }
      case GotoW(lbl) -> {
        match mapGet(seen, lbl) {
          case None -> seen.add(lbl, true)
          case Some(_) -> ()
        }
      }
      case TableSwitch(_, _, nCases, swIdx) -> {
        val defLbl = asm.swDefaults[swIdx]
        match mapGet(seen, defLbl) {
          case None -> seen.add(defLbl, true)
          case Some(_) -> ()
        }
        val off = asm.swTableOff[swIdx]
        var ti = 0
        while ti < nCases {
          val cl = asm.swTableLabels[off + ti]
          match mapGet(seen, cl) {
            case None -> seen.add(cl, true)
            case Some(_) -> ()
          }
          ti = ti + 1
        }
      }
      case LookupSwitch(nPairs, swIdx) -> {
        val defLbl = asm.swDefaults[swIdx]
        match mapGet(seen, defLbl) {
          case None -> seen.add(defLbl, true)
          case Some(_) -> ()
        }
        val off = asm.swLookupOff[swIdx]
        var li = 0
        while li < nPairs {
          val cl = asm.swLookupLabels[off + li]
          match mapGet(seen, cl) {
            case None -> seen.add(cl, true)
            case Some(_) -> ()
          }
          li = li + 1
        }
      }
      case _ -> ()
    }
    bi = bi + 1
  }
  seen
}

/// Like `assembleCode` but embeds a StackMapTable so the result is accepted
/// by the JVM verifier in class files with major version >= 50 (Java 6+).
///
/// `frameLocals` must describe the types of all local variable slots at every
/// branch target and exception handler entry point.  The operand stack is
/// assumed empty at every branch target; exception handler entries carry one
/// element (java/lang/Throwable) on the stack automatically.
///
/// Exception handlers registered via `addExceptionHandler` are emitted into
/// the Code attribute's exception table, and StackMapTable `full_frame` entries
/// are generated at each unique handler label with stack = [Throwable].
pub func assembleCodeWithFrames(
  asm: in MethodAssembler,
  maxStack: in Int,
  maxLocals: in Int,
  frameLocals: in List[VerifierType],
): Attribute {
  val pool = asm.pool
  val ar = assembleRaw(asm)
  val targets = collectBranchLabels(asm)

  // Collect unique handler labels; they need full_frame entries with Throwable on stack.
  val handlerLabels: Map[String, Bool] = newMap()
  var hli = 0
  while hli < asm.exnHandlers.count {
    val h = asm.exnHandlers[hli]
    match mapGet(handlerLabels, h.handlerLabel) {
      case None -> handlerLabels.add(h.handlerLabel, true)
      case Some(_) -> ()
    }
    hli = hli + 1
  }

  val smBuf = writerNew()
  var smCount = 0
  var prevOff = -1

  var si = 0
  while si < asm.insns.count {
    match asm.insns[si] {
      case Label(nm) -> {
        if targets.containsKey(nm) {
          match mapGet(ar.labelOffsets, nm) {
            case Some(off) -> {
              val delta = off - prevOff - 1
              writerByte(smBuf, 255)             // full_frame tag
              writerU2(smBuf, delta)             // offset_delta
              writerU2(smBuf, frameLocals.count)
              var vi = 0
              while vi < frameLocals.count {
                emitVerifierTypeBc(frameLocals[vi], pool, smBuf)
                vi = vi + 1
              }
              writerU2(smBuf, 0)                 // stack = empty
              smCount = smCount + 1
              prevOff = off
            }
            case None -> ()
          }
        } else {
          if handlerLabels.containsKey(nm) {
            match mapGet(ar.labelOffsets, nm) {
              case Some(off) -> {
                val delta = off - prevOff - 1
                writerByte(smBuf, 255)           // full_frame tag
                writerU2(smBuf, delta)           // offset_delta
                writerU2(smBuf, frameLocals.count)
                var vi = 0
                while vi < frameLocals.count {
                  emitVerifierTypeBc(frameLocals[vi], pool, smBuf)
                  vi = vi + 1
                }
                writerU2(smBuf, 1)               // stack has one element: Throwable
                emitVerifierTypeBc(VObject(className = "java/lang/Throwable"), pool, smBuf)
                smCount = smCount + 1
                prevOff = off
              }
              case None -> ()
            }
          }
        }
      }
      case _ -> ()
    }
    si = si + 1
  }

  val codeW = writerNew()
  writerU2(codeW, maxStack)
  writerU2(codeW, maxLocals)
  writerU4(codeW, ar.codeBytes.count)
  writerByteList(codeW, ar.codeBytes)
  writerU2(codeW, asm.exnHandlers.count)
  var hi = 0
  while hi < asm.exnHandlers.count {
    val h = asm.exnHandlers[hi]
    writerU2(codeW, resolveLbl(ar.labelOffsets, h.startLabel))
    writerU2(codeW, resolveLbl(ar.labelOffsets, h.endLabel))
    writerU2(codeW, resolveLbl(ar.labelOffsets, h.handlerLabel))
    writerU2(codeW, h.catchType)
    hi = hi + 1
  }
  if smCount > 0 {
    writerU2(codeW, 1)                           // attributes_count = 1
    writerU2(codeW, poolUtf8(pool, "StackMapTable"))
    val smBytes = writerToList(smBuf)
    writerU4(codeW, 2 + smBytes.count)
    writerU2(codeW, smCount)
    writerByteList(codeW, smBytes)
  } else {
    writerU2(codeW, 0)                           // no nested attributes
  }
  attrFromWriter("Code", codeW)
}

/// Like `assembleCodeWithFrames` but uses `asm.peakStack` instead of a caller-supplied maxStack.
pub func assembleCodeWithFramesInferred(
  asm: in MethodAssembler, maxLocals: in Int, frameLocals: in List[VerifierType]
): Attribute {
  assembleCodeWithFrames(asm, asm.peakStack, maxLocals, frameLocals)
}

// ── Typed emitter helpers ─────────────────────────────────────────────────────
// One function per logical instruction form.  Each appends to `asm.insns`.
/// Define a label at the current position.  Branch targets name labels.
pub func emitLabel(asm: in MethodAssembler, name: in String): Unit {
  emitInsn(asm, Label(name = name))
}

// ── Constants ────────────────────────────────────────────────────────────────
pub func emitNop(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_NOP))
}

pub func emitAconstNull(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ACONST_NULL))
}

/// Push integer constant -1 to 5 using iconst_* (≤ 5 only).
/// Use `emitBipush` / `emitSipush` / `emitLdcInt` for larger values.
pub func emitIconst(asm: in MethodAssembler, v: in Int): Unit {
  match v {
    case -1 -> emitInsn(asm, Nullary(op = OP_ICONST_M1))
    case 0 -> emitInsn(asm, Nullary(op = OP_ICONST_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_ICONST_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_ICONST_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_ICONST_3))
    case 4 -> emitInsn(asm, Nullary(op = OP_ICONST_4))
    case 5 -> emitInsn(asm, Nullary(op = OP_ICONST_5))
    case _ -> panic("emitIconst: value out of range [-1, 5]")
  }
}

pub func emitLconst(asm: in MethodAssembler, v: in Int): Unit {
  match v {
    case 0 -> emitInsn(asm, Nullary(op = OP_LCONST_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_LCONST_1))
    case _ -> panic("emitLconst: value out of range [0, 1]")
  }
}

pub func emitDconst(asm: in MethodAssembler, v: in Int): Unit {
  match v {
    case 0 -> emitInsn(asm, Nullary(op = OP_DCONST_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_DCONST_1))
    case _ -> panic("emitDconst: value out of range [0, 1]")
  }
}

pub func emitBipush(asm: in MethodAssembler, v: in Int): Unit {
  emitInsn(asm, U1(op = OP_BIPUSH, imm = v))
}

pub func emitSipush(asm: in MethodAssembler, v: in Int): Unit {
  emitInsn(asm, U2(op = OP_SIPUSH, imm = v))
}

/// Push an integer constant using the smallest encoding.
pub func emitPushInt(asm: in MethodAssembler, v: in Int): Unit {
  if v >= -1 and v <= 5 {
    emitIconst(asm, v)
  } else if v >= -128 and v <= 127 {
    emitBipush(asm, v)
  } else if v >= -32768 and v <= 32767 {
    emitSipush(asm, v)
  } else {
    emitInsn(asm, Ldc(poolIdx = poolInteger(asm.pool, v)))
  }
}

/// Push a long constant via ldc2_w.
pub func emitPushLong(asm: in MethodAssembler, v: in Long): Unit {
  emitInsn(asm, Ldc2W(poolIdx = poolLong(asm.pool, v)))
}

/// Push a double constant via ldc2_w.
pub func emitPushFloat(asm: in MethodAssembler, v: in Double): Unit {
  val idx = poolFloat(asm.pool, v)
  if idx <= 255 {
    emitInsn(asm, Ldc(poolIdx = idx))
  } else {
    emitInsn(asm, LdcW(poolIdx = idx))
  }
}

pub func emitPushDouble(asm: in MethodAssembler, v: in Double): Unit {
  emitInsn(asm, Ldc2W(poolIdx = poolDouble(asm.pool, v)))
}

/// Push a String constant via ldc / ldc_w.
pub func emitPushString(asm: in MethodAssembler, s: in String): Unit {
  val idx = poolString(asm.pool, s)
  if idx <= 255 {
    emitInsn(asm, Ldc(poolIdx = idx))
  } else {
    emitInsn(asm, LdcW(poolIdx = idx))
  }
}

// ── Loads ─────────────────────────────────────────────────────────────────────
pub func emitIload(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_ILOAD_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_ILOAD_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_ILOAD_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_ILOAD_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_ILOAD, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_ILOAD, slot = slot))
  }
}

pub func emitLload(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_LLOAD_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_LLOAD_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_LLOAD_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_LLOAD_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_LLOAD, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_LLOAD, slot = slot))
  }
}

pub func emitDload(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_DLOAD_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_DLOAD_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_DLOAD_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_DLOAD_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_DLOAD, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_DLOAD, slot = slot))
  }
}

pub func emitAload(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_ALOAD_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_ALOAD_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_ALOAD_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_ALOAD_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_ALOAD, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_ALOAD, slot = slot))
  }
}

// ── Stores ────────────────────────────────────────────────────────────────────
pub func emitIstore(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_ISTORE_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_ISTORE_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_ISTORE_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_ISTORE_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_ISTORE, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_ISTORE, slot = slot))
  }
}

pub func emitLstore(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_LSTORE_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_LSTORE_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_LSTORE_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_LSTORE_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_LSTORE, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_LSTORE, slot = slot))
  }
}

pub func emitDstore(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_DSTORE_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_DSTORE_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_DSTORE_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_DSTORE_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_DSTORE, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_DSTORE, slot = slot))
  }
}

pub func emitFload(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_FLOAD_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_FLOAD_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_FLOAD_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_FLOAD_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_FLOAD, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_FLOAD, slot = slot))
  }
}

pub func emitFstore(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_FSTORE_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_FSTORE_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_FSTORE_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_FSTORE_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_FSTORE, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_FSTORE, slot = slot))
  }
}

pub func emitAstore(asm: in MethodAssembler, slot: in Int): Unit {
  match slot {
    case 0 -> emitInsn(asm, Nullary(op = OP_ASTORE_0))
    case 1 -> emitInsn(asm, Nullary(op = OP_ASTORE_1))
    case 2 -> emitInsn(asm, Nullary(op = OP_ASTORE_2))
    case 3 -> emitInsn(asm, Nullary(op = OP_ASTORE_3))
    case _ -> if slot <= 255 then emitInsn(asm, LocalU1(op = OP_ASTORE, slot = slot)) else emitInsn(asm, LocalU2Wide(op = OP_ASTORE, slot = slot))
  }
}

// ── Stack operations ──────────────────────────────────────────────────────────
pub func emitPop(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_POP))
}

pub func emitPop2(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_POP2))
}

pub func emitDup(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DUP))
}

pub func emitDupX1(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DUP_X1))
}

pub func emitDup2(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DUP2))
}

pub func emitSwap(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_SWAP))
}

// ── Integer arithmetic ────────────────────────────────────────────────────────
pub func emitIadd(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IADD))
}

pub func emitIsub(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ISUB))
}

pub func emitImul(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IMUL))
}

pub func emitIdiv(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IDIV))
}

pub func emitIrem(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IREM))
}

pub func emitIneg(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_INEG))
}

pub func emitIand(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IAND))
}

pub func emitIor(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IOR))
}

pub func emitIxor(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IXOR))
}

pub func emitIshl(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ISHL))
}

pub func emitIshr(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ISHR))
}

pub func emitIushr(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IUSHR))
}

pub func emitIinc(asm: in MethodAssembler, slot: in Int, delta: in Int): Unit {
  emitInsn(asm, Iinc(slot = slot, delta = delta))
}

// ── Long arithmetic ───────────────────────────────────────────────────────────
pub func emitLadd(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LADD))
}

pub func emitLsub(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LSUB))
}

pub func emitLmul(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LMUL))
}

pub func emitLdiv(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LDIV))
}

pub func emitLrem(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LREM))
}

pub func emitLneg(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LNEG))
}

pub func emitLcmp(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LCMP))
}

pub func emitLand(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LAND))
}

pub func emitLor(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LOR))
}

pub func emitLxor(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LXOR))
}

pub func emitLshl(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LSHL))
}

pub func emitLshr(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LSHR))
}

pub func emitLushr(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LUSHR))
}

// ── Float arithmetic ──────────────────────────────────────────────────────────
pub func emitFconst0(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FCONST_0))
}

pub func emitFconst1(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FCONST_1))
}

pub func emitFconst2(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FCONST_2))
}

pub func emitFadd(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FADD))
}

pub func emitFsub(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FSUB))
}

pub func emitFmul(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FMUL))
}

pub func emitFdiv(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FDIV))
}

pub func emitFrem(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FREM))
}

pub func emitFneg(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FNEG))
}

pub func emitFcmpg(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FCMPG))
}

pub func emitFcmpl(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FCMPL))
}

// ── Double arithmetic ─────────────────────────────────────────────────────────
pub func emitDadd(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DADD))
}

pub func emitDsub(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DSUB))
}

pub func emitDmul(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DMUL))
}

pub func emitDdiv(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DDIV))
}

pub func emitDrem(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DREM))
}

pub func emitDneg(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DNEG))
}

pub func emitDcmpg(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DCMPG))
}

pub func emitDcmpl(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DCMPL))
}

// ── Type conversions ──────────────────────────────────────────────────────────
pub func emitI2f(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_I2F))
}

pub func emitI2l(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_I2L))
}

pub func emitI2d(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_I2D))
}

pub func emitL2i(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_L2I))
}

pub func emitL2f(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_L2F))
}

pub func emitL2d(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_L2D))
}

pub func emitF2i(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_F2I))
}

pub func emitF2l(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_F2L))
}

pub func emitF2d(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_F2D))
}

pub func emitD2i(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_D2I))
}

pub func emitD2l(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_D2L))
}

pub func emitD2f(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_D2F))
}

pub func emitI2b(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_I2B))
}

pub func emitI2c(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_I2C))
}

pub func emitI2s(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_I2S))
}

// ── Field access ──────────────────────────────────────────────────────────────
/// getstatic  / putstatic  / getfield / putfield.
/// Pass the pre-computed Fieldref pool index as `poolRef`.
pub func emitGetstatic(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_GETSTATIC, classIdx = poolRef, natIdx = 0))
}

pub func emitPutstatic(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_PUTSTATIC, classIdx = poolRef, natIdx = 0))
}

pub func emitGetfield(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_GETFIELD, classIdx = poolRef, natIdx = 0))
}

pub func emitPutfield(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_PUTFIELD, classIdx = poolRef, natIdx = 0))
}

// ── Method invocation ─────────────────────────────────────────────────────────
/// invokevirtual.  `poolRef` is a pre-computed Methodref index.
pub func emitInvokevirtual(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_INVOKEVIRTUAL, classIdx = poolRef, natIdx = 0))
}

/// invokespecial (constructors, private methods, super calls).
pub func emitInvokespecial(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_INVOKESPECIAL, classIdx = poolRef, natIdx = 0))
}

/// invokestatic.
pub func emitInvokestatic(asm: in MethodAssembler, poolRef: in Int): Unit {
  emitInsn(asm, Ref(op = OP_INVOKESTATIC, classIdx = poolRef, natIdx = 0))
}

/// invokeinterface.  `poolRef` is an InterfaceMethodref pool index.
/// `argCount` = 1 + number of method parameters (includes receiver).
pub func emitInvokeinterface(asm: in MethodAssembler, poolRef: in Int, argCount: in Int): Unit {
  emitInsn(asm, InvokeInterface(classIdx = poolRef, natIdx = 0, argCount = argCount))
}

/// invokedynamic.  `dynIdx` is a pre-computed InvokeDynamic pool index.
pub func emitInvokedynamic(asm: in MethodAssembler, dynIdx: in Int): Unit {
  emitInsn(asm, InvokeDynamic(dynIdx = dynIdx))
}

// ── Object creation ───────────────────────────────────────────────────────────
/// new — allocate an uninitialised instance.  `classIdx` is a Class pool index.
pub func emitNew(asm: in MethodAssembler, classIdx: in Int): Unit {
  emitInsn(asm, ClassRef(op = OP_NEW, classIdx = classIdx))
}

/// checkcast.
pub func emitCheckcast(asm: in MethodAssembler, classIdx: in Int): Unit {
  emitInsn(asm, ClassRef(op = OP_CHECKCAST, classIdx = classIdx))
}

/// instanceof.
pub func emitInstanceof(asm: in MethodAssembler, classIdx: in Int): Unit {
  emitInsn(asm, ClassRef(op = OP_INSTANCEOF, classIdx = classIdx))
}

/// newarray (for primitive arrays).  `typeCode` is one of T_INT, T_LONG, etc.
pub func emitNewarray(asm: in MethodAssembler, typeCode: in Int): Unit {
  emitInsn(asm, NewArray(typeCode = typeCode))
}

/// anewarray (for reference-type arrays).
pub func emitAnewarray(asm: in MethodAssembler, classIdx: in Int): Unit {
  emitInsn(asm, ANewArray(classIdx = classIdx))
}

/// multianewarray — creates a multi-dimensional array.
/// `classIdx` is the pool index for the full array-type descriptor (e.g. "[[I").
/// `dims` is the number of dimensions to allocate (must be ≥ 1).
pub func emitMultiANewArray(asm: in MethodAssembler, classIdx: in Int, dims: in Int): Unit {
  emitInsn(asm, MultiANewArray(classIdx = classIdx, dims = dims))
}

pub func emitArraylength(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ARRAYLENGTH))
}

// ── Array element access ──────────────────────────────────────────────────────
pub func emitIaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IALOAD))
}

pub func emitLaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LALOAD))
}

pub func emitFaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FALOAD))
}

pub func emitDaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DALOAD))
}

pub func emitAaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_AALOAD))
}

pub func emitBaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_BALOAD))
}

pub func emitCaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_CALOAD))
}

pub func emitSaload(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_SALOAD))
}

pub func emitIastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IASTORE))
}

pub func emitLastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LASTORE))
}

pub func emitFastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FASTORE))
}

pub func emitDastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DASTORE))
}

pub func emitAastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_AASTORE))
}

pub func emitBastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_BASTORE))
}

pub func emitCastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_CASTORE))
}

pub func emitSastore(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_SASTORE))
}

// ── Returns ───────────────────────────────────────────────────────────────────
pub func emitIreturn(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_IRETURN))
}

pub func emitFreturn(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_FRETURN))
}

pub func emitLreturn(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_LRETURN))
}

pub func emitDreturn(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_DRETURN))
}

pub func emitAreturn(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ARETURN))
}

pub func emitReturn(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_RETURN))
}

pub func emitAthrow(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_ATHROW))
}

// ── Branches ──────────────────────────────────────────────────────────────────
pub func emitGoto(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_GOTO, label = label))
}

pub func emitGotoW(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, GotoW(label = label))
}

pub func emitIfeq(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFEQ, label = label))
}

pub func emitIfne(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFNE, label = label))
}

pub func emitIflt(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFLT, label = label))
}

pub func emitIfge(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFGE, label = label))
}

pub func emitIfgt(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFGT, label = label))
}

pub func emitIfle(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFLE, label = label))
}

pub func emitIfIcmpeq(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ICMPEQ, label = label))
}

pub func emitIfIcmpne(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ICMPNE, label = label))
}

pub func emitIfIcmplt(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ICMPLT, label = label))
}

pub func emitIfIcmpge(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ICMPGE, label = label))
}

pub func emitIfIcmpgt(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ICMPGT, label = label))
}

pub func emitIfIcmple(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ICMPLE, label = label))
}

pub func emitIfAcmpeq(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ACMPEQ, label = label))
}

pub func emitIfAcmpne(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IF_ACMPNE, label = label))
}

pub func emitIfnull(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFNULL, label = label))
}

pub func emitIfnonnull(asm: in MethodAssembler, label: in String): Unit {
  emitInsn(asm, BranchInsn(op = OP_IFNONNULL, label = label))
}

// ── Switch instructions ───────────────────────────────────────────────────────
/// tableswitch — integer switch over a contiguous range [low..high].
/// `caseLabels` must contain exactly `high - low + 1` label names, one
/// per case value in order.  `defaultLabel` is taken if the key is out of range.
pub func emitTableSwitch(
  asm: in MethodAssembler,
  low: in Int,
  high: in Int,
  defaultLabel: in String,
  caseLabels: in List[String],
): Unit {
  val idx = asm.swDefaults.count
  val off = asm.swTableLabels.count
  val nCases = high - low + 1
  asm.swDefaults.add(defaultLabel)
  asm.swTableOff.add(off)
  var i = 0
  while i < caseLabels.count {
    asm.swTableLabels.add(caseLabels[i])
    i = i + 1
  }
  emitInsn(asm, TableSwitch(low = low, high = high, nCases = nCases, swIdx = idx))
}

/// lookupswitch — integer switch over arbitrary (key, label) pairs.
/// `pairs` must be sorted by key in ascending order (JVMS requirement).
/// `defaultLabel` is taken when no key matches.
pub func emitLookupSwitch(asm: in MethodAssembler, defaultLabel: in String, pairs: in List[SwitchPair]): Unit {
  val idx = asm.swDefaults.count
  val off = asm.swLookupKeys.count
  asm.swDefaults.add(defaultLabel)
  asm.swLookupOff.add(off)
  var i = 0
  while i < pairs.count {
    asm.swLookupKeys.add(pairs[i].key)
    asm.swLookupLabels.add(pairs[i].label)
    i = i + 1
  }
  emitInsn(asm, LookupSwitch(nPairs = pairs.count, swIdx = idx))
}

// ── Monitor (for synchronized blocks) ────────────────────────────────────────
pub func emitMonitorenter(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_MONITORENTER))
}

pub func emitMonitorexit(asm: in MethodAssembler): Unit {
  emitInsn(asm, Nullary(op = OP_MONITOREXIT))
}

// ── B113-B114 helpers ─────────────────────────────────────────────────────────
/// Push the `Class<T>` literal for `className` via ldc_w.
pub func emitPushClass(asm: in MethodAssembler, className: in String): Unit {
  val idx = poolClass(asm.pool, className)
  emitInsn(asm, LdcW(poolIdx = idx))
}

/// Allocate a 1-element `int[]` and store it into local slot `targetSlot`.
pub func emitOutAllocInt(asm: in MethodAssembler, targetSlot: in Int): Unit {
  emitPushInt(asm, 1)
  emitNewarray(asm, 10)   // T_INT = 10
  emitAstore(asm, targetSlot)
}

/// Store the int in local `valueSlot` into index 0 of the `int[]` at `arraySlot`.
pub func emitOutStoreInt(asm: in MethodAssembler, arraySlot: in Int, valueSlot: in Int): Unit {
  emitAload(asm, arraySlot)
  emitIconst(asm, 0)
  emitIload(asm, valueSlot)
  emitIastore(asm)
}

/// Load the int at index 0 of the `int[]` at `arraySlot` onto the stack.
pub func emitOutLoadInt(asm: in MethodAssembler, arraySlot: in Int): Unit {
  emitAload(asm, arraySlot)
  emitIconst(asm, 0)
  emitIaload(asm)
}
