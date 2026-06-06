//! msil/opcodes.l — ECMA-335 CIL instruction IR and two-pass assembler (Stage M2b).
//!
//! Provides:
//!   Insn          — typed instruction union (compact form, parameterised by opcode byte)
//!   MethodBody    — mutable instruction accumulator with label support
//!   mbEmit / emitXxx — instruction builder functions
//!   serializeMethodBody — two-pass assembler: resolves branches, writes tiny/fat header + body
//!
//! Two-pass assembly:
//!   Pass 1 — walk insns, record Map[Int→Int] of label ID → byte offset.
//!   Pass 2 — emit bytes, substituting resolved 4-byte signed offsets for branch targets.
//!
//! Branch encoding:
//!   All branches use the long (4-byte-offset) form.  The short form is not
//!   emitted; a future optimisation pass can shrink them.
//!
//! References: ECMA-335 6th edition §III (CIL instruction set).
package Msil.Opcodes

import Msil.Kernel
import Std.Core
import Std.Collections

// ── Opcode byte constants (ECMA-335 §III) ────────────────────────────────────
// Single-byte nullary opcodes
pub val OP_NOP: Int = 0x00

pub val OP_LDARG_0: Int = 0x02

pub val OP_LDARG_1: Int = 0x03

pub val OP_LDARG_2: Int = 0x04

pub val OP_LDARG_3: Int = 0x05

pub val OP_LDLOC_0: Int = 0x06

pub val OP_LDLOC_1: Int = 0x07

pub val OP_LDLOC_2: Int = 0x08

pub val OP_LDLOC_3: Int = 0x09

pub val OP_STLOC_0: Int = 0x0A

pub val OP_STLOC_1: Int = 0x0B

pub val OP_STLOC_2: Int = 0x0C

pub val OP_STLOC_3: Int = 0x0D

pub val OP_LDNULL: Int = 0x14

pub val OP_LDC_I4_M1: Int = 0x15

pub val OP_LDC_I4_0: Int = 0x16

pub val OP_LDC_I4_1: Int = 0x17

pub val OP_LDC_I4_2: Int = 0x18

pub val OP_LDC_I4_3: Int = 0x19

pub val OP_LDC_I4_4: Int = 0x1A

pub val OP_LDC_I4_5: Int = 0x1B

pub val OP_LDC_I4_6: Int = 0x1C

pub val OP_LDC_I4_7: Int = 0x1D

pub val OP_LDC_I4_8: Int = 0x1E

pub val OP_DUP: Int = 0x25

pub val OP_POP: Int = 0x26

pub val OP_RET: Int = 0x2A

pub val OP_LDIND_I1: Int = 0x46

pub val OP_LDIND_U1: Int = 0x47

pub val OP_LDIND_I2: Int = 0x48

pub val OP_LDIND_U2: Int = 0x49

pub val OP_LDIND_I4: Int = 0x4A

pub val OP_LDIND_U4: Int = 0x4B

pub val OP_LDIND_I: Int = 0x4D

pub val OP_LDIND_I8: Int = 0x4C

pub val OP_LDIND_R4: Int = 0x4E

pub val OP_LDIND_R8: Int = 0x4F

pub val OP_LDIND_REF: Int = 0x50

pub val OP_STIND_REF: Int = 0x51

pub val OP_STIND_I1: Int = 0x52

pub val OP_STIND_I2: Int = 0x53

pub val OP_STIND_I4: Int = 0x54

pub val OP_STIND_I8: Int = 0x55

pub val OP_STIND_R4: Int = 0x56

pub val OP_STIND_R8: Int = 0x57

pub val OP_ADD: Int = 0x58

pub val OP_SUB: Int = 0x59

pub val OP_MUL: Int = 0x5A

pub val OP_DIV: Int = 0x5B

pub val OP_DIV_UN: Int = 0x5C

pub val OP_REM: Int = 0x5D

pub val OP_REM_UN: Int = 0x5E

pub val OP_AND: Int = 0x5F

pub val OP_OR: Int = 0x60

pub val OP_XOR: Int = 0x61

pub val OP_SHL: Int = 0x62

pub val OP_SHR: Int = 0x63

pub val OP_SHR_UN: Int = 0x64

pub val OP_NEG: Int = 0x65

pub val OP_NOT: Int = 0x66

pub val OP_CONV_I1: Int = 0x67

pub val OP_CONV_I2: Int = 0x68

pub val OP_CONV_I4: Int = 0x69

pub val OP_CONV_I8: Int = 0x6A

pub val OP_CONV_R4: Int = 0x6B

pub val OP_CONV_R8: Int = 0x6C

pub val OP_CONV_U4: Int = 0x6D

pub val OP_CONV_U8: Int = 0x6E

pub val OP_CONV_R_UN: Int = 0x76

pub val OP_CKFINITE: Int = 0xC3

pub val OP_THROW: Int = 0x7A

pub val OP_LDLEN: Int = 0x8E

pub val OP_LDELEM_I1: Int = 0x90

pub val OP_LDELEM_U1: Int = 0x91

pub val OP_LDELEM_I2: Int = 0x92

pub val OP_LDELEM_U2: Int = 0x93

pub val OP_LDELEM_I4: Int = 0x94

pub val OP_LDELEM_U4: Int = 0x95

pub val OP_LDELEM_I8: Int = 0x96

pub val OP_LDELEM_I: Int = 0x97

pub val OP_LDELEM_R4: Int = 0x98

pub val OP_LDELEM_R8: Int = 0x99

pub val OP_LDELEM_REF: Int = 0x9A

pub val OP_STELEM_I: Int = 0x9B

pub val OP_STELEM_I1: Int = 0x9C

pub val OP_STELEM_I2: Int = 0x9D

pub val OP_STELEM_I4: Int = 0x9E

pub val OP_STELEM_I8: Int = 0x9F

pub val OP_STELEM_R4: Int = 0xA0

pub val OP_STELEM_R8: Int = 0xA1

pub val OP_STELEM_REF: Int = 0xA2

pub val OP_ADD_OVF: Int = 0xD6

pub val OP_ADD_OVF_UN: Int = 0xD7

pub val OP_MUL_OVF: Int = 0xD8

pub val OP_MUL_OVF_UN: Int = 0xD9

pub val OP_SUB_OVF: Int = 0xDA

pub val OP_SUB_OVF_UN: Int = 0xDB

pub val OP_ENDFINALLY: Int = 0xDC

pub val OP_CONV_I: Int = 0xD3

pub val OP_STIND_I: Int = 0xDF

pub val OP_CONV_U: Int = 0xE0

pub val OP_CONV_U1: Int = 0xD2

pub val OP_CONV_U2: Int = 0xD1

pub val OP_CONV_OVF_I1_UN: Int = 0x82

pub val OP_CONV_OVF_I2_UN: Int = 0x83

pub val OP_CONV_OVF_I4_UN: Int = 0x84

pub val OP_CONV_OVF_I8_UN: Int = 0x85

pub val OP_CONV_OVF_U1_UN: Int = 0x86

pub val OP_CONV_OVF_U2_UN: Int = 0x87

pub val OP_CONV_OVF_U4_UN: Int = 0x88

pub val OP_CONV_OVF_U8_UN: Int = 0x89

pub val OP_CONV_OVF_I1: Int = 0xB3

pub val OP_CONV_OVF_U1: Int = 0xB4

pub val OP_CONV_OVF_I2: Int = 0xB5

pub val OP_CONV_OVF_U2: Int = 0xB6

pub val OP_CONV_OVF_I4: Int = 0xB7

pub val OP_CONV_OVF_U4: Int = 0xB8

pub val OP_CONV_OVF_I8: Int = 0xB9

pub val OP_CONV_OVF_U8: Int = 0xBA

// Short-form arg/local opcodes (single-byte opcode + 1-byte index)
pub val OP_LDARG_S: Int = 0x0E

pub val OP_LDARGA_S: Int = 0x0F

pub val OP_STARG_S: Int = 0x10

pub val OP_LDLOC_S: Int = 0x11

pub val OP_LDLOCA_S: Int = 0x12

pub val OP_STLOC_S: Int = 0x13

// Integer constant opcodes
pub val OP_LDC_I4_S: Int = 0x1F

pub val OP_LDC_I4: Int = 0x20

pub val OP_LDC_I8: Int = 0x21

pub val OP_LDC_R4: Int = 0x22

pub val OP_LDC_R8: Int = 0x23

// Token opcodes (single-byte opcode + 4-byte metadata token)
pub val OP_CALL: Int = 0x28

pub val OP_CALLVIRT: Int = 0x6F

pub val OP_LDOBJ: Int = 0x71

pub val OP_LDSTR: Int = 0x72

pub val OP_NEWOBJ: Int = 0x73

pub val OP_CASTCLASS: Int = 0x74

pub val OP_ISINST: Int = 0x75

pub val OP_STOBJ: Int = 0x81

pub val OP_BOX: Int = 0x8C

pub val OP_NEWARR: Int = 0x8D

pub val OP_LDELEMA: Int = 0x8F

pub val OP_LDELEM: Int = 0xA3

pub val OP_STELEM: Int = 0xA4

pub val OP_UNBOX_ANY: Int = 0xA5

pub val OP_LDFLD: Int = 0x7B

pub val OP_LDFLDA: Int = 0x7C

pub val OP_STFLD: Int = 0x7D

pub val OP_LDSFLD: Int = 0x7E

pub val OP_LDSFLDA: Int = 0x7F

pub val OP_STSFLD: Int = 0x80

pub val OP_LDTOKEN: Int = 0xD0

// Branch opcodes (single-byte opcode + 4-byte signed offset)
pub val OP_BR: Int = 0x38

pub val OP_BRFALSE: Int = 0x39

pub val OP_BRTRUE: Int = 0x3A

pub val OP_BEQ: Int = 0x3B

pub val OP_BGE: Int = 0x3C

pub val OP_BGT: Int = 0x3D

pub val OP_BLE: Int = 0x3E

pub val OP_BLT: Int = 0x3F

pub val OP_BNE_UN: Int = 0x40

pub val OP_BGE_UN: Int = 0x41

pub val OP_BGT_UN: Int = 0x42

pub val OP_BLE_UN: Int = 0x43

pub val OP_BLT_UN: Int = 0x44

pub val OP_SWITCH: Int = 0x45

pub val OP_LEAVE: Int = 0xDD

// 0xFE-prefixed nullary opcodes (second byte)
pub val OP2_CEQ: Int = 0x01

pub val OP2_CGT: Int = 0x02

pub val OP2_CGT_UN: Int = 0x03

pub val OP2_CLT: Int = 0x04

pub val OP2_CLT_UN: Int = 0x05

pub val OP2_VOLATILE: Int = 0x13

pub val OP2_LOCALLOC: Int = 0x0F

pub val OP2_TAIL: Int = 0x14

pub val OP2_CPBLK: Int = 0x17

pub val OP2_INITBLK: Int = 0x18

pub val OP2_RETHROW: Int = 0x1A

// 0xFE-prefixed token opcodes (second byte)
pub val OP2_LDFTN: Int = 0x06

pub val OP2_LDVIRTFTN: Int = 0x07

pub val OP2_INITOBJ: Int = 0x15

pub val OP2_CONSTRAINED: Int = 0x16

pub val OP2_SIZEOF: Int = 0x1C

// 0xFE-prefixed full-form arg/local opcodes (second byte + 2-byte index)
pub val OP2_LDARG: Int = 0x09

pub val OP2_LDARGA: Int = 0x0A

pub val OP2_STARG: Int = 0x0B

pub val OP2_LDLOC: Int = 0x0C

pub val OP2_LDLOCA: Int = 0x0D

pub val OP2_STLOC: Int = 0x0E

// ── Typed instruction union ──────────────────────────────────────────────────
//
// Each case covers a family of instructions with the same operand shape:
//   Label(id)       — pseudo: zero bytes; marks a branch target.
//   Nullary(op)     — 1 byte: single-byte opcode, no operand.
//   Nullary2(op)    — 2 bytes: 0xFE + op.
//   LdcI4S(v)       — 2 bytes: 0x1F + sbyte constant.
//   LdcI4(v)        — 5 bytes: 0x20 + i32 LE.
//   LdcI8(v)        — 9 bytes: 0x21 + i64 LE.
//   LdcR4(v)        — 5 bytes: 0x22 + f32 LE.
//   LdcR8(v)        — 9 bytes: 0x23 + f64 LE.
//   Token(op,tok)   — 5 bytes: op + token LE.
//   Token2(op,tok)  — 6 bytes: 0xFE + op + token LE.
//   VarS(op,idx)    — 2 bytes: op + u8 index.
//   VarF(op,idx)    — 4 bytes: 0xFE + op + u16 index LE.
//   BranchInsn(op,lbl)  — 5 bytes: op + i32 LE offset (resolved from label ID).
//   Switch(n,swIdx) — variable: 0x45 + u32 count + count * i32 offsets.
//                     n=target count; swIdx=start offset into MethodBody.swData.
//                     List[T] fields in union cases are erased by D035 and cannot be
//                     accessed, so switch targets live in a parallel flat list on MethodBody.
pub union Insn {
  case Label(id: Int)
  case Nullary(op: Int)
  case Nullary2(op: Int)
  case LdcI4S(value: Int)
  case LdcI4(value: Int)
  case LdcI8(value: Long)
  case LdcR4(value: Double)
  case LdcR8(value: Double)
  case Token(op: Int, token: Int)
  case Token2(op: Int, token: Int)
  case VarS(op: Int, index: Int)
  case VarF(op: Int, index: Int)
  case BranchInsn(op: Int, label: Int)
  case Switch(n: Int, swIdx: Int)
}

// ── Smart constructors ────────────────────────────────────────────────────────
pub func iNop(): Insn = Nullary(op = OP_NOP)

pub func iRet(): Insn = Nullary(op = OP_RET)

pub func iDup(): Insn = Nullary(op = OP_DUP)

pub func iPop(): Insn = Nullary(op = OP_POP)

pub func iLdnull(): Insn = Nullary(op = OP_LDNULL)

pub func iLdarg_0(): Insn = Nullary(op = OP_LDARG_0)

pub func iLdarg_1(): Insn = Nullary(op = OP_LDARG_1)

pub func iLdarg_2(): Insn = Nullary(op = OP_LDARG_2)

pub func iLdarg_3(): Insn = Nullary(op = OP_LDARG_3)

pub func iLdloc_0(): Insn = Nullary(op = OP_LDLOC_0)

pub func iLdloc_1(): Insn = Nullary(op = OP_LDLOC_1)

pub func iLdloc_2(): Insn = Nullary(op = OP_LDLOC_2)

pub func iLdloc_3(): Insn = Nullary(op = OP_LDLOC_3)

pub func iStloc_0(): Insn = Nullary(op = OP_STLOC_0)

pub func iStloc_1(): Insn = Nullary(op = OP_STLOC_1)

pub func iStloc_2(): Insn = Nullary(op = OP_STLOC_2)

pub func iStloc_3(): Insn = Nullary(op = OP_STLOC_3)

pub func iLdc_I4_M1(): Insn = Nullary(op = OP_LDC_I4_M1)

pub func iLdc_I4_0(): Insn = Nullary(op = OP_LDC_I4_0)

pub func iLdc_I4_1(): Insn = Nullary(op = OP_LDC_I4_1)

pub func iLdc_I4_2(): Insn = Nullary(op = OP_LDC_I4_2)

pub func iLdc_I4_3(): Insn = Nullary(op = OP_LDC_I4_3)

pub func iLdc_I4_4(): Insn = Nullary(op = OP_LDC_I4_4)

pub func iLdc_I4_5(): Insn = Nullary(op = OP_LDC_I4_5)

pub func iLdc_I4_6(): Insn = Nullary(op = OP_LDC_I4_6)

pub func iLdc_I4_7(): Insn = Nullary(op = OP_LDC_I4_7)

pub func iLdc_I4_8(): Insn = Nullary(op = OP_LDC_I4_8)

pub func iLdc_I4_S(v: in Int): Insn = LdcI4S(value = v)

pub func iLdc_I4(v: in Int): Insn = LdcI4(value = v)

pub func iLdc_I8(v: in Long): Insn = LdcI8(value = v)

pub func iLdc_R4(v: in Double): Insn = LdcR4(value = v)

pub func iLdc_R8(v: in Double): Insn = LdcR8(value = v)

pub func iLdstr(tok: in Int): Insn = Token(op = OP_LDSTR, token = tok)

pub func iCall(tok: in Int): Insn = Token(op = OP_CALL, token = tok)

pub func iCallvirt(tok: in Int): Insn = Token(op = OP_CALLVIRT, token = tok)

pub func iNewobj(tok: in Int): Insn = Token(op = OP_NEWOBJ, token = tok)

pub func iNewarr(tok: in Int): Insn = Token(op = OP_NEWARR, token = tok)

pub func iCastclass(tok: in Int): Insn = Token(op = OP_CASTCLASS, token = tok)

pub func iIsinst(tok: in Int): Insn = Token(op = OP_ISINST, token = tok)

pub func iBox(tok: in Int): Insn = Token(op = OP_BOX, token = tok)

pub func iUnbox_Any(tok: in Int): Insn = Token(op = OP_UNBOX_ANY, token = tok)

pub func iLdfld(tok: in Int): Insn = Token(op = OP_LDFLD, token = tok)

pub func iLdflda(tok: in Int): Insn = Token(op = OP_LDFLDA, token = tok)

pub func iStfld(tok: in Int): Insn = Token(op = OP_STFLD, token = tok)

pub func iLdsfld(tok: in Int): Insn = Token(op = OP_LDSFLD, token = tok)

pub func iLdsflda(tok: in Int): Insn = Token(op = OP_LDSFLDA, token = tok)

pub func iStsfld(tok: in Int): Insn = Token(op = OP_STSFLD, token = tok)

pub func iLdobj(tok: in Int): Insn = Token(op = OP_LDOBJ, token = tok)

pub func iStobj(tok: in Int): Insn = Token(op = OP_STOBJ, token = tok)

pub func iLdelem(tok: in Int): Insn = Token(op = OP_LDELEM, token = tok)

pub func iStelem(tok: in Int): Insn = Token(op = OP_STELEM, token = tok)

pub func iLdelema(tok: in Int): Insn = Token(op = OP_LDELEMA, token = tok)

pub func iInitobj(tok: in Int): Insn = Token2(op = OP2_INITOBJ, token = tok)

pub func iLdftn(tok: in Int): Insn = Token2(op = OP2_LDFTN, token = tok)

pub func iLdvirtftn(tok: in Int): Insn = Token2(op = OP2_LDVIRTFTN, token = tok)

pub func iConstrained(tok: in Int): Insn = Token2(op = OP2_CONSTRAINED, token = tok)

pub func iSizeof(tok: in Int): Insn = Token2(op = OP2_SIZEOF, token = tok)

pub func iLdtoken(tok: in Int): Insn = Token(op = OP_LDTOKEN, token = tok)

pub func iAdd(): Insn = Nullary(op = OP_ADD)

pub func iSub(): Insn = Nullary(op = OP_SUB)

pub func iMul(): Insn = Nullary(op = OP_MUL)

pub func iDiv(): Insn = Nullary(op = OP_DIV)

pub func iDivUn(): Insn = Nullary(op = OP_DIV_UN)

pub func iRem(): Insn = Nullary(op = OP_REM)

pub func iRemUn(): Insn = Nullary(op = OP_REM_UN)

pub func iNeg(): Insn = Nullary(op = OP_NEG)

pub func iNot(): Insn = Nullary(op = OP_NOT)

pub func iAnd(): Insn = Nullary(op = OP_AND)

pub func iOr(): Insn = Nullary(op = OP_OR)

pub func iXor(): Insn = Nullary(op = OP_XOR)

pub func iShl(): Insn = Nullary(op = OP_SHL)

pub func iShr(): Insn = Nullary(op = OP_SHR)

pub func iShrUn(): Insn = Nullary(op = OP_SHR_UN)

pub func iAdd_Ovf(): Insn = Nullary(op = OP_ADD_OVF)

pub func iAdd_Ovf_Un(): Insn = Nullary(op = OP_ADD_OVF_UN)

pub func iSub_Ovf(): Insn = Nullary(op = OP_SUB_OVF)

pub func iSub_Ovf_Un(): Insn = Nullary(op = OP_SUB_OVF_UN)

pub func iMul_Ovf(): Insn = Nullary(op = OP_MUL_OVF)

pub func iMul_Ovf_Un(): Insn = Nullary(op = OP_MUL_OVF_UN)

pub func iConv_I(): Insn = Nullary(op = OP_CONV_I)

pub func iConv_U(): Insn = Nullary(op = OP_CONV_U)

pub func iConv_I1(): Insn = Nullary(op = OP_CONV_I1)

pub func iConv_I2(): Insn = Nullary(op = OP_CONV_I2)

pub func iConv_I4(): Insn = Nullary(op = OP_CONV_I4)

pub func iConv_I8(): Insn = Nullary(op = OP_CONV_I8)

pub func iConv_R4(): Insn = Nullary(op = OP_CONV_R4)

pub func iConv_R8(): Insn = Nullary(op = OP_CONV_R8)

pub func iConv_U1(): Insn = Nullary(op = OP_CONV_U1)

pub func iConv_U2(): Insn = Nullary(op = OP_CONV_U2)

pub func iConv_U4(): Insn = Nullary(op = OP_CONV_U4)

pub func iConv_U8(): Insn = Nullary(op = OP_CONV_U8)

pub func iConv_R_Un(): Insn = Nullary(op = OP_CONV_R_UN)

pub func iCkfinite(): Insn = Nullary(op = OP_CKFINITE)

pub func iConv_Ovf_I1(): Insn = Nullary(op = OP_CONV_OVF_I1)

pub func iConv_Ovf_U1(): Insn = Nullary(op = OP_CONV_OVF_U1)

pub func iConv_Ovf_I2(): Insn = Nullary(op = OP_CONV_OVF_I2)

pub func iConv_Ovf_U2(): Insn = Nullary(op = OP_CONV_OVF_U2)

pub func iConv_Ovf_I4(): Insn = Nullary(op = OP_CONV_OVF_I4)

pub func iConv_Ovf_U4(): Insn = Nullary(op = OP_CONV_OVF_U4)

pub func iConv_Ovf_I8(): Insn = Nullary(op = OP_CONV_OVF_I8)

pub func iConv_Ovf_U8(): Insn = Nullary(op = OP_CONV_OVF_U8)

pub func iConv_Ovf_I1_Un(): Insn = Nullary(op = OP_CONV_OVF_I1_UN)

pub func iConv_Ovf_I2_Un(): Insn = Nullary(op = OP_CONV_OVF_I2_UN)

pub func iConv_Ovf_I4_Un(): Insn = Nullary(op = OP_CONV_OVF_I4_UN)

pub func iConv_Ovf_I8_Un(): Insn = Nullary(op = OP_CONV_OVF_I8_UN)

pub func iConv_Ovf_U1_Un(): Insn = Nullary(op = OP_CONV_OVF_U1_UN)

pub func iConv_Ovf_U2_Un(): Insn = Nullary(op = OP_CONV_OVF_U2_UN)

pub func iConv_Ovf_U4_Un(): Insn = Nullary(op = OP_CONV_OVF_U4_UN)

pub func iConv_Ovf_U8_Un(): Insn = Nullary(op = OP_CONV_OVF_U8_UN)

pub func iLdlen(): Insn = Nullary(op = OP_LDLEN)

pub func iThrow(): Insn = Nullary(op = OP_THROW)

pub func iLocalloc(): Insn = Nullary2(op = OP2_LOCALLOC)

pub func iVolatile(): Insn = Nullary2(op = OP2_VOLATILE)

pub func iTail(): Insn = Nullary2(op = OP2_TAIL)

pub func iCpblk(): Insn = Nullary2(op = OP2_CPBLK)

pub func iInitblk(): Insn = Nullary2(op = OP2_INITBLK)

pub func iRethrow(): Insn = Nullary2(op = OP2_RETHROW)

pub func iEndfinally(): Insn = Nullary(op = OP_ENDFINALLY)

pub func iStelem_Ref(): Insn = Nullary(op = OP_STELEM_REF)

pub func iLdelem_I1(): Insn = Nullary(op = OP_LDELEM_I1)

pub func iLdelem_U1(): Insn = Nullary(op = OP_LDELEM_U1)

pub func iLdelem_I2(): Insn = Nullary(op = OP_LDELEM_I2)

pub func iLdelem_U2(): Insn = Nullary(op = OP_LDELEM_U2)

pub func iLdelem_I4(): Insn = Nullary(op = OP_LDELEM_I4)

pub func iLdelem_U4(): Insn = Nullary(op = OP_LDELEM_U4)

pub func iLdelem_I8(): Insn = Nullary(op = OP_LDELEM_I8)

pub func iLdelem_I(): Insn = Nullary(op = OP_LDELEM_I)

pub func iLdelem_R4(): Insn = Nullary(op = OP_LDELEM_R4)

pub func iLdelem_R8(): Insn = Nullary(op = OP_LDELEM_R8)

pub func iLdelem_Ref(): Insn = Nullary(op = OP_LDELEM_REF)

pub func iStelem_I(): Insn = Nullary(op = OP_STELEM_I)

pub func iStelem_I1(): Insn = Nullary(op = OP_STELEM_I1)

pub func iStelem_I2(): Insn = Nullary(op = OP_STELEM_I2)

pub func iStelem_I4(): Insn = Nullary(op = OP_STELEM_I4)

pub func iStelem_I8(): Insn = Nullary(op = OP_STELEM_I8)

pub func iStelem_R4(): Insn = Nullary(op = OP_STELEM_R4)

pub func iStelem_R8(): Insn = Nullary(op = OP_STELEM_R8)

pub func iLdind_I1(): Insn = Nullary(op = OP_LDIND_I1)

pub func iLdind_U1(): Insn = Nullary(op = OP_LDIND_U1)

pub func iLdind_I(): Insn = Nullary(op = OP_LDIND_I)

pub func iLdind_I2(): Insn = Nullary(op = OP_LDIND_I2)

pub func iLdind_U2(): Insn = Nullary(op = OP_LDIND_U2)

pub func iLdind_I4(): Insn = Nullary(op = OP_LDIND_I4)

pub func iLdind_U4(): Insn = Nullary(op = OP_LDIND_U4)

pub func iLdind_I8(): Insn = Nullary(op = OP_LDIND_I8)

pub func iLdind_R4(): Insn = Nullary(op = OP_LDIND_R4)

pub func iLdind_R8(): Insn = Nullary(op = OP_LDIND_R8)

pub func iLdind_Ref(): Insn = Nullary(op = OP_LDIND_REF)

pub func iStind_I(): Insn = Nullary(op = OP_STIND_I)

pub func iStind_I1(): Insn = Nullary(op = OP_STIND_I1)

pub func iStind_I2(): Insn = Nullary(op = OP_STIND_I2)

pub func iStind_I4(): Insn = Nullary(op = OP_STIND_I4)

pub func iStind_I8(): Insn = Nullary(op = OP_STIND_I8)

pub func iStind_R4(): Insn = Nullary(op = OP_STIND_R4)

pub func iStind_R8(): Insn = Nullary(op = OP_STIND_R8)

pub func iStind_Ref(): Insn = Nullary(op = OP_STIND_REF)

pub func iCeq(): Insn = Nullary2(op = OP2_CEQ)

pub func iCgt(): Insn = Nullary2(op = OP2_CGT)

pub func iCgt_Un(): Insn = Nullary2(op = OP2_CGT_UN)

pub func iClt(): Insn = Nullary2(op = OP2_CLT)

pub func iClt_Un(): Insn = Nullary2(op = OP2_CLT_UN)

pub func iLdarg_S(n: in Int): Insn = VarS(op = OP_LDARG_S, index = n)

pub func iLdarga_S(n: in Int): Insn = VarS(op = OP_LDARGA_S, index = n)

pub func iStarg_S(n: in Int): Insn = VarS(op = OP_STARG_S, index = n)

pub func iLdloc_S(n: in Int): Insn = VarS(op = OP_LDLOC_S, index = n)

pub func iLdloca_S(n: in Int): Insn = VarS(op = OP_LDLOCA_S, index = n)

pub func iStloc_S(n: in Int): Insn = VarS(op = OP_STLOC_S, index = n)

pub func iLdarg(n: in Int): Insn = VarF(op = OP2_LDARG, index = n)

pub func iLdarga(n: in Int): Insn = VarF(op = OP2_LDARGA, index = n)

pub func iLdloc(n: in Int): Insn = VarF(op = OP2_LDLOC, index = n)

pub func iLdloca(n: in Int): Insn = VarF(op = OP2_LDLOCA, index = n)

pub func iStloc(n: in Int): Insn = VarF(op = OP2_STLOC, index = n)

pub func iBr(lbl: in Int): Insn = BranchInsn(op = OP_BR, label = lbl)

pub func iBrfalse(lbl: in Int): Insn = BranchInsn(op = OP_BRFALSE, label = lbl)

pub func iBrtrue(lbl: in Int): Insn = BranchInsn(op = OP_BRTRUE, label = lbl)

pub func iBeq(lbl: in Int): Insn = BranchInsn(op = OP_BEQ, label = lbl)

pub func iBge(lbl: in Int): Insn = BranchInsn(op = OP_BGE, label = lbl)

pub func iBge_Un(lbl: in Int): Insn = BranchInsn(op = OP_BGE_UN, label = lbl)

pub func iBgt(lbl: in Int): Insn = BranchInsn(op = OP_BGT, label = lbl)

pub func iBgt_Un(lbl: in Int): Insn = BranchInsn(op = OP_BGT_UN, label = lbl)

pub func iBlt(lbl: in Int): Insn = BranchInsn(op = OP_BLT, label = lbl)

pub func iBlt_Un(lbl: in Int): Insn = BranchInsn(op = OP_BLT_UN, label = lbl)

pub func iBle(lbl: in Int): Insn = BranchInsn(op = OP_BLE, label = lbl)

pub func iBle_Un(lbl: in Int): Insn = BranchInsn(op = OP_BLE_UN, label = lbl)

pub func iBne_Un(lbl: in Int): Insn = BranchInsn(op = OP_BNE_UN, label = lbl)

pub func iLeave(lbl: in Int): Insn = BranchInsn(op = OP_LEAVE, label = lbl)

// iSwitch is not provided: Switch targets are stored in MethodBody.swData; use emitSwitch.
// ── MethodBody ───────────────────────────────────────────────────────────────
// Exception handling clause for a method body (ECMA-335 §II.25.4.6).
// flags: 0=typed catch, 2=finally, 4=fault.
// tryStart/tryEnd:       label IDs bracketing the try region (tryEnd = first insn after).
// handlerStart/handlerEnd: label IDs bracketing the handler (handlerEnd = first insn after).
// catchToken: metadata token for the catch type (TypeRef/TypeDef), or 0 for finally/fault.
pub record EHClause {
  flags: Int
  tryStart: Int
  tryEnd: Int
  handlerStart: Int
  handlerEnd: Int
  catchToken: Int
}

pub record MethodBody {
  insns: List[Insn]
  maxStack: Int
  localSig: Int
  nextLbl: Int
  swData: List[Int]
  ehClauses: List[EHClause]
}

pub func newMethodBody(): MethodBody {
  MethodBody(insns = newList(), maxStack = 8, localSig = 0, nextLbl = 0, swData = newList(), ehClauses = newList())
}

pub func mbAddEHClause(b: in MethodBody, clause: in EHClause): Unit {
  b.ehClauses.add(clause)
}

// Allocate a fresh label ID.  The label is unplaced until mbMarkLabel is called.
pub func mbNewLabel(b: in MethodBody): Int {
  val id = b.nextLbl
  b.nextLbl = id + 1
  id
}

// Place `id` at the current instruction-stream position.
pub func mbMarkLabel(b: in MethodBody, id: in Int): Unit {
  b.insns.add(Label(id = id))
}

pub func mbEmit(b: in MethodBody, i: in Insn): Unit {
  b.insns.add(i)
}

pub func mbSetMaxStack(b: in MethodBody, n: in Int): Unit {
  b.maxStack = n
}

pub func mbSetLocalSig(b: in MethodBody, tok: in Int): Unit {
  b.localSig = tok
}

// ── Convenience emit wrappers ─────────────────────────────────────────────────
pub func emitNop(b: in MethodBody): Unit = mbEmit(b, iNop())

pub func emitRet(b: in MethodBody): Unit = mbEmit(b, iRet())

pub func emitDup(b: in MethodBody): Unit = mbEmit(b, iDup())

pub func emitPop(b: in MethodBody): Unit = mbEmit(b, iPop())

pub func emitLdnull(b: in MethodBody): Unit = mbEmit(b, iLdnull())

pub func emitLdarg_0(b: in MethodBody): Unit = mbEmit(b, iLdarg_0())

pub func emitLdarg_1(b: in MethodBody): Unit = mbEmit(b, iLdarg_1())

pub func emitLdarg_2(b: in MethodBody): Unit = mbEmit(b, iLdarg_2())

pub func emitLdarg_3(b: in MethodBody): Unit = mbEmit(b, iLdarg_3())

pub func emitLdloc_0(b: in MethodBody): Unit = mbEmit(b, iLdloc_0())

pub func emitLdloc_1(b: in MethodBody): Unit = mbEmit(b, iLdloc_1())

pub func emitLdloc_2(b: in MethodBody): Unit = mbEmit(b, iLdloc_2())

pub func emitLdloc_3(b: in MethodBody): Unit = mbEmit(b, iLdloc_3())

pub func emitStloc_0(b: in MethodBody): Unit = mbEmit(b, iStloc_0())

pub func emitStloc_1(b: in MethodBody): Unit = mbEmit(b, iStloc_1())

pub func emitStloc_2(b: in MethodBody): Unit = mbEmit(b, iStloc_2())

pub func emitStloc_3(b: in MethodBody): Unit = mbEmit(b, iStloc_3())

pub func emitLdc_I4_M1(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_M1())

pub func emitLdc_I4_0(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_0())

pub func emitLdc_I4_1(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_1())

pub func emitLdc_I4_2(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_2())

pub func emitLdc_I4_3(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_3())

pub func emitLdc_I4_4(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_4())

pub func emitLdc_I4_5(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_5())

pub func emitLdc_I4_6(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_6())

pub func emitLdc_I4_7(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_7())

pub func emitLdc_I4_8(b: in MethodBody): Unit = mbEmit(b, iLdc_I4_8())

pub func emitLdc_I4_S(b: in MethodBody, v: in Int): Unit = mbEmit(b, iLdc_I4_S(v))

pub func emitLdc_I4(b: in MethodBody, v: in Int): Unit = mbEmit(b, iLdc_I4(v))

pub func emitLdc_I8(b: in MethodBody, v: in Long): Unit = mbEmit(b, iLdc_I8(v))

pub func emitLdc_R4(b: in MethodBody, v: in Double): Unit = mbEmit(b, iLdc_R4(v))

pub func emitLdc_R8(b: in MethodBody, v: in Double): Unit = mbEmit(b, iLdc_R8(v))

pub func emitLdstr(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdstr(tok))

pub func emitCall(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iCall(tok))

pub func emitCallvirt(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iCallvirt(tok))

pub func emitNewobj(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iNewobj(tok))

pub func emitNewarr(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iNewarr(tok))

pub func emitCastclass(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iCastclass(tok))

pub func emitIsinst(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iIsinst(tok))

pub func emitBox(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iBox(tok))

pub func emitUnbox_Any(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iUnbox_Any(tok))

pub func emitLdfld(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdfld(tok))

pub func emitLdflda(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdflda(tok))

pub func emitStfld(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iStfld(tok))

pub func emitLdsfld(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdsfld(tok))

pub func emitStsfld(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iStsfld(tok))

pub func emitLdobj(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdobj(tok))

pub func emitStobj(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iStobj(tok))

pub func emitLdelem(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdelem(tok))

pub func emitStelem(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iStelem(tok))

pub func emitLdelema(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdelema(tok))

pub func emitInitobj(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iInitobj(tok))

pub func emitLdftn(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdftn(tok))

pub func emitSizeof(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iSizeof(tok))

pub func emitLdtoken(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdtoken(tok))

pub func emitAdd(b: in MethodBody): Unit = mbEmit(b, iAdd())

pub func emitSub(b: in MethodBody): Unit = mbEmit(b, iSub())

pub func emitMul(b: in MethodBody): Unit = mbEmit(b, iMul())

pub func emitDiv(b: in MethodBody): Unit = mbEmit(b, iDiv())

pub func emitDivUn(b: in MethodBody): Unit = mbEmit(b, iDivUn())

pub func emitRem(b: in MethodBody): Unit = mbEmit(b, iRem())

pub func emitRemUn(b: in MethodBody): Unit = mbEmit(b, iRemUn())

pub func emitNeg(b: in MethodBody): Unit = mbEmit(b, iNeg())

pub func emitNot(b: in MethodBody): Unit = mbEmit(b, iNot())

pub func emitAnd(b: in MethodBody): Unit = mbEmit(b, iAnd())

pub func emitOr(b: in MethodBody): Unit = mbEmit(b, iOr())

pub func emitXor(b: in MethodBody): Unit = mbEmit(b, iXor())

pub func emitShl(b: in MethodBody): Unit = mbEmit(b, iShl())

pub func emitShr(b: in MethodBody): Unit = mbEmit(b, iShr())

pub func emitShrUn(b: in MethodBody): Unit = mbEmit(b, iShrUn())

pub func emitAdd_Ovf(b: in MethodBody): Unit = mbEmit(b, iAdd_Ovf())

pub func emitAdd_Ovf_Un(b: in MethodBody): Unit = mbEmit(b, iAdd_Ovf_Un())

pub func emitSub_Ovf(b: in MethodBody): Unit = mbEmit(b, iSub_Ovf())

pub func emitSub_Ovf_Un(b: in MethodBody): Unit = mbEmit(b, iSub_Ovf_Un())

pub func emitMul_Ovf(b: in MethodBody): Unit = mbEmit(b, iMul_Ovf())

pub func emitMul_Ovf_Un(b: in MethodBody): Unit = mbEmit(b, iMul_Ovf_Un())

pub func emitConv_I(b: in MethodBody): Unit = mbEmit(b, iConv_I())

pub func emitConv_U(b: in MethodBody): Unit = mbEmit(b, iConv_U())

pub func emitConv_I1(b: in MethodBody): Unit = mbEmit(b, iConv_I1())

pub func emitConv_I2(b: in MethodBody): Unit = mbEmit(b, iConv_I2())

pub func emitConv_I4(b: in MethodBody): Unit = mbEmit(b, iConv_I4())

pub func emitConv_I8(b: in MethodBody): Unit = mbEmit(b, iConv_I8())

pub func emitConv_R4(b: in MethodBody): Unit = mbEmit(b, iConv_R4())

pub func emitConv_R8(b: in MethodBody): Unit = mbEmit(b, iConv_R8())

pub func emitConv_U1(b: in MethodBody): Unit = mbEmit(b, iConv_U1())

pub func emitConv_U2(b: in MethodBody): Unit = mbEmit(b, iConv_U2())

pub func emitConv_U4(b: in MethodBody): Unit = mbEmit(b, iConv_U4())

pub func emitConv_U8(b: in MethodBody): Unit = mbEmit(b, iConv_U8())

pub func emitConv_R_Un(b: in MethodBody): Unit = mbEmit(b, iConv_R_Un())

pub func emitCkfinite(b: in MethodBody): Unit = mbEmit(b, iCkfinite())

pub func emitConv_Ovf_I1(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I1())

pub func emitConv_Ovf_U1(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U1())

pub func emitConv_Ovf_I2(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I2())

pub func emitConv_Ovf_U2(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U2())

pub func emitConv_Ovf_I4(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I4())

pub func emitConv_Ovf_U4(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U4())

pub func emitConv_Ovf_I8(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I8())

pub func emitConv_Ovf_U8(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U8())

pub func emitConv_Ovf_I1_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I1_Un())

pub func emitConv_Ovf_I2_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I2_Un())

pub func emitConv_Ovf_I4_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I4_Un())

pub func emitConv_Ovf_I8_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_I8_Un())

pub func emitConv_Ovf_U1_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U1_Un())

pub func emitConv_Ovf_U2_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U2_Un())

pub func emitConv_Ovf_U4_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U4_Un())

pub func emitConv_Ovf_U8_Un(b: in MethodBody): Unit = mbEmit(b, iConv_Ovf_U8_Un())

pub func emitLdlen(b: in MethodBody): Unit = mbEmit(b, iLdlen())

pub func emitThrow(b: in MethodBody): Unit = mbEmit(b, iThrow())

pub func emitLocalloc(b: in MethodBody): Unit = mbEmit(b, iLocalloc())

pub func emitVolatile(b: in MethodBody): Unit = mbEmit(b, iVolatile())

pub func emitTail(b: in MethodBody): Unit = mbEmit(b, iTail())

pub func emitCpblk(b: in MethodBody): Unit = mbEmit(b, iCpblk())

pub func emitInitblk(b: in MethodBody): Unit = mbEmit(b, iInitblk())

pub func emitRethrow(b: in MethodBody): Unit = mbEmit(b, iRethrow())

pub func emitEndfinally(b: in MethodBody): Unit = mbEmit(b, iEndfinally())

pub func emitStelem_Ref(b: in MethodBody): Unit = mbEmit(b, iStelem_Ref())

pub func emitLdelem_I1(b: in MethodBody): Unit = mbEmit(b, iLdelem_I1())

pub func emitLdelem_U1(b: in MethodBody): Unit = mbEmit(b, iLdelem_U1())

pub func emitLdelem_I2(b: in MethodBody): Unit = mbEmit(b, iLdelem_I2())

pub func emitLdelem_U2(b: in MethodBody): Unit = mbEmit(b, iLdelem_U2())

pub func emitLdelem_I4(b: in MethodBody): Unit = mbEmit(b, iLdelem_I4())

pub func emitLdelem_U4(b: in MethodBody): Unit = mbEmit(b, iLdelem_U4())

pub func emitLdelem_I8(b: in MethodBody): Unit = mbEmit(b, iLdelem_I8())

pub func emitLdelem_I(b: in MethodBody): Unit = mbEmit(b, iLdelem_I())

pub func emitLdelem_R4(b: in MethodBody): Unit = mbEmit(b, iLdelem_R4())

pub func emitLdelem_R8(b: in MethodBody): Unit = mbEmit(b, iLdelem_R8())

pub func emitLdelem_Ref(b: in MethodBody): Unit = mbEmit(b, iLdelem_Ref())

pub func emitStelem_I(b: in MethodBody): Unit = mbEmit(b, iStelem_I())

pub func emitStelem_I1(b: in MethodBody): Unit = mbEmit(b, iStelem_I1())

pub func emitStelem_I2(b: in MethodBody): Unit = mbEmit(b, iStelem_I2())

pub func emitStelem_I4(b: in MethodBody): Unit = mbEmit(b, iStelem_I4())

pub func emitStelem_I8(b: in MethodBody): Unit = mbEmit(b, iStelem_I8())

pub func emitStelem_R4(b: in MethodBody): Unit = mbEmit(b, iStelem_R4())

pub func emitStelem_R8(b: in MethodBody): Unit = mbEmit(b, iStelem_R8())

pub func emitLdind_I1(b: in MethodBody): Unit = mbEmit(b, iLdind_I1())

pub func emitLdind_U1(b: in MethodBody): Unit = mbEmit(b, iLdind_U1())

pub func emitLdind_I2(b: in MethodBody): Unit = mbEmit(b, iLdind_I2())

pub func emitLdind_U2(b: in MethodBody): Unit = mbEmit(b, iLdind_U2())

pub func emitLdind_I(b: in MethodBody): Unit = mbEmit(b, iLdind_I())

pub func emitLdind_I4(b: in MethodBody): Unit = mbEmit(b, iLdind_I4())

pub func emitLdind_U4(b: in MethodBody): Unit = mbEmit(b, iLdind_U4())

pub func emitLdind_I8(b: in MethodBody): Unit = mbEmit(b, iLdind_I8())

pub func emitLdind_R4(b: in MethodBody): Unit = mbEmit(b, iLdind_R4())

pub func emitLdind_R8(b: in MethodBody): Unit = mbEmit(b, iLdind_R8())

pub func emitLdind_Ref(b: in MethodBody): Unit = mbEmit(b, iLdind_Ref())

pub func emitStind_I1(b: in MethodBody): Unit = mbEmit(b, iStind_I1())

pub func emitStind_I2(b: in MethodBody): Unit = mbEmit(b, iStind_I2())

pub func emitStind_I(b: in MethodBody): Unit = mbEmit(b, iStind_I())

pub func emitStind_I4(b: in MethodBody): Unit = mbEmit(b, iStind_I4())

pub func emitStind_I8(b: in MethodBody): Unit = mbEmit(b, iStind_I8())

pub func emitStind_R4(b: in MethodBody): Unit = mbEmit(b, iStind_R4())

pub func emitStind_R8(b: in MethodBody): Unit = mbEmit(b, iStind_R8())

pub func emitStind_Ref(b: in MethodBody): Unit = mbEmit(b, iStind_Ref())

pub func emitLdsflda(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdsflda(tok))

pub func emitLdvirtftn(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iLdvirtftn(tok))

pub func emitConstrained(b: in MethodBody, tok: in Int): Unit = mbEmit(b, iConstrained(tok))

pub func emitCeq(b: in MethodBody): Unit = mbEmit(b, iCeq())

pub func emitCgt(b: in MethodBody): Unit = mbEmit(b, iCgt())

pub func emitCgt_Un(b: in MethodBody): Unit = mbEmit(b, iCgt_Un())

pub func emitClt(b: in MethodBody): Unit = mbEmit(b, iClt())

pub func emitClt_Un(b: in MethodBody): Unit = mbEmit(b, iClt_Un())

pub func emitLdarg_S(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdarg_S(n))

pub func emitLdarga_S(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdarga_S(n))

pub func emitStarg_S(b: in MethodBody, n: in Int): Unit = mbEmit(b, iStarg_S(n))

pub func emitLdloc_S(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdloc_S(n))

pub func emitLdloca_S(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdloca_S(n))

pub func emitStloc_S(b: in MethodBody, n: in Int): Unit = mbEmit(b, iStloc_S(n))

pub func emitLdarg(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdarg(n))

pub func emitLdarga(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdarga(n))

pub func emitLdloc(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdloc(n))

pub func emitLdloca(b: in MethodBody, n: in Int): Unit = mbEmit(b, iLdloca(n))

pub func emitStloc(b: in MethodBody, n: in Int): Unit = mbEmit(b, iStloc(n))

pub func emitBr(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBr(lbl))

pub func emitBrfalse(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBrfalse(lbl))

pub func emitBrtrue(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBrtrue(lbl))

pub func emitBeq(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBeq(lbl))

pub func emitBge(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBge(lbl))

pub func emitBge_Un(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBge_Un(lbl))

pub func emitBgt(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBgt(lbl))

pub func emitBgt_Un(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBgt_Un(lbl))

pub func emitBlt(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBlt(lbl))

pub func emitBlt_Un(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBlt_Un(lbl))

pub func emitBle(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBle(lbl))

pub func emitBle_Un(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBle_Un(lbl))

pub func emitBne_Un(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iBne_Un(lbl))

pub func emitLeave(b: in MethodBody, lbl: in Int): Unit = mbEmit(b, iLeave(lbl))

pub func emitSwitch(b: in MethodBody, ts: in List[Int]): Unit {
  val swIdx = b.swData.count
  var ti = 0
  while ti < ts.count {
    b.swData.add(ts[ti])
    ti = ti + 1
  }
  mbEmit(b, Switch(n = ts.count, swIdx = swIdx))
}

// ── Two-pass assembler ────────────────────────────────────────────────────────
func insnSize(i: in Insn): Int {
  match i {
    case Label(_) -> 0
    case Nullary(_) -> 1
    case Nullary2(_) -> 2
    case LdcI4S(_) -> 2
    case LdcI4(_) -> 5
    case LdcI8(_) -> 9
    case LdcR4(_) -> 5
    case LdcR8(_) -> 9
    case Token(_, _) -> 5
    case Token2(_, _) -> 6
    case VarS(_, _) -> 2
    case VarF(_, _) -> 4
    case BranchInsn(_, _) -> 5
    case Switch(n, _) -> 1 + 4 + n * 4
  }
}

// Resolves `lbl` in `offsets`; returns 0 if unplaced (caller's error).
func resolveLbl(offsets: in Map[Int, Int], lbl: in Int): Int {
  match mapGet(offsets, lbl) {
    case Some(t) -> t
    case None -> 0
  }
}

// Return the IL byte count of `b.insns` (labels contribute 0).
pub func methodBodyCodeSize(b: in MethodBody): Int {
  var pos = 0
  var idx = 0
  while idx < b.insns.count {
    val ins = b.insns[idx]
    match ins {
      case Label(_) -> ()
      case _ -> {
        pos = pos + insnSize(ins)
      }
    }
    idx = idx + 1
  }
  return pos
}

// Does serializing `b` produce a fat method header (vs the 1-byte tiny header)?
// Mirrors the predicate inside `serializeMethodBody`.  Fat is required when:
//   - any local variable is declared (`localSig != 0`),
//   - an exception-handling section is present, OR
//   - the IL code size exceeds 63 bytes (tiny encodes size in 6 bits).
// Fat method headers must be 4-byte aligned per ECMA-335 II.25.4.5; the
// assembler uses this predicate to know whether to inject pre-method padding.
pub func methodBodyIsFatHeader(b: in MethodBody): Bool {
  if b.localSig != 0 {
    return true
  }
  if b.ehClauses.count > 0 {
    return true
  }
  // ECMA-335 §II.25.4.2: tiny header has implicit maxStack = 8.
  // Force fat header whenever the method needs more than 8 stack slots
  // (e.g. a constructor call with ≥9 arguments).
  if b.maxStack > 8 {
    return true
  }
  return methodBodyCodeSize(b) > 63
}

// Serialize `b` to `w`, prepending the method header (tiny or fat).
// Tiny header is used when `methodBodyIsFatHeader(b)` is false (codeSize ≤ 63
// AND no locals AND no EH clauses).  Fat header is 12 bytes: flags(2) |
// maxStack(2) | codeSize(4) | localSig(4).
pub func serializeMethodBody(b: in MethodBody, w: in ByteWriter): Unit {
  // Pass 1: compute label offsets.
  val offsets: Map[Int, Int] = newMap()
  var pos = 0
  var idx = 0
  while idx < b.insns.count {
    val insn1 = b.insns[idx]
    match insn1 {
      case Label(id) -> offsets.add(id, pos)
      case _ -> {
        pos = pos + insnSize(insn1)
      }
    }
    idx = idx + 1
  }
  val codeSize = pos

  val hasEH = b.ehClauses.count > 0

  // Write method header.  The tiny-vs-fat decision is delegated to
  // `methodBodyIsFatHeader` so the assembler's pre-body alignment pass
  // and this serializer agree on which bodies need 4-byte alignment
  // (ECMA-335 II.25.4.5; issue #962 + review #985).
  if not methodBodyIsFatHeader(b) {
    bufU1(w, (codeSize * 4) + 2)
  } else {
    // Fat header flags: FatFormat(0x3) | InitLocals(0x10) | MoreSects(0x08 if EH present)
    val fflags1 = if hasEH { 0x1B } else { 0x13 }
    bufU1(w, fflags1)
    bufU1(w, 0x30)
    bufU2(w, b.maxStack)
    bufU4(w, codeSize)
    bufU4(w, b.localSig)
  }

  // Pass 2: emit instruction bytes.
  var pc = 0
  var ji = 0
  while ji < b.insns.count {
    match b.insns[ji] {
      case Label(_) -> ()
      case Nullary(op) -> {
        bufU1(w, op)
        pc = pc + 1
      }
      case Nullary2(op) -> {
        bufU1(w, 0xFE)
        bufU1(w, op)
        pc = pc + 2
      }
      case LdcI4S(v) -> {
        bufU1(w, 0x1F)
        bufU1(w, v)
        pc = pc + 2
      }
      case LdcI4(v) -> {
        bufU1(w, 0x20)
        bufU4(w, v)
        pc = pc + 5
      }
      case LdcI8(v) -> {
        bufU1(w, 0x21)
        bufI8Le(w, v)
        pc = pc + 9
      }
      case LdcR4(v) -> {
        bufU1(w, 0x22)
        bufF4Le(w, v)
        pc = pc + 5
      }
      case LdcR8(v) -> {
        bufU1(w, 0x23)
        bufF8Le(w, v)
        pc = pc + 9
      }
      case Token(op, tok) -> {
        bufU1(w, op)
        bufU4(w, tok)
        pc = pc + 5
      }
      case Token2(op, tok) -> {
        bufU1(w, 0xFE)
        bufU1(w, op)
        bufU4(w, tok)
        pc = pc + 6
      }
      case VarS(op, n) -> {
        bufU1(w, op)
        bufU1(w, n)
        pc = pc + 2
      }
      case VarF(op, n) -> {
        bufU1(w, 0xFE)
        bufU1(w, op)
        bufU2(w, n)
        pc = pc + 4
      }
      case BranchInsn(op, lbl) -> {
        val nextPc = pc + 5
        val targetPc = resolveLbl(offsets, lbl)
        bufU1(w, op)
        bufU4(w, targetPc - nextPc)
        pc = pc + 5
      }
      case Switch(n, swIdx) -> {
        val nextPc = pc + 1 + 4 + n * 4
        bufU1(w, 0x45)
        bufU4(w, n)
        var ti = 0
        while ti < n {
          val targetPc = resolveLbl(offsets, b.swData[swIdx + ti])
          bufU4(w, targetPc - nextPc)
          ti = ti + 1
        }
        pc = pc + 1 + 4 + n * 4
      }
    }
    ji = ji + 1
  }

  // Write fat exception handling section (ECMA-335 §II.25.4.5) if needed.
  if hasEH {
    // Align to 4-byte boundary.
    while bufLen(w) % 4 != 0 {
      bufU1(w, 0x00)
    }

    val nClauses = b.ehClauses.count
    // Fat EH section: kind(1) + dataSize-u24(3) + n*24 bytes.
    val dataSize = 4 + nClauses * 24
    bufU1(w, 0x41)             // SectEHTable(0x01) | SectFatFormat(0x40)
    bufU1(w, dataSize % 256)   // dataSize low byte
    bufU1(w, (dataSize / 256) % 256)
    bufU1(w, (dataSize / 65536) % 256)

    var ci = 0
    while ci < nClauses {
      val clause = b.ehClauses[ci]
      val tStart = resolveLbl(offsets, clause.tryStart)
      val tEnd = resolveLbl(offsets, clause.tryEnd)
      val hStart = resolveLbl(offsets, clause.handlerStart)
      val hEnd = resolveLbl(offsets, clause.handlerEnd)
      bufU4(w, clause.flags)
      bufU4(w, tStart)
      bufU4(w, tEnd - tStart)
      bufU4(w, hStart)
      bufU4(w, hEnd - hStart)
      bufU4(w, clause.catchToken)
      ci = ci + 1
    }
  }
}
