// msil_self_test_m2b.l — Stage M2b self-test for the typed CIL instruction IR.
//
// Exercises Msil.Opcodes: the Insn union, MethodBody accumulator, and the
// two-pass assembler (serializeMethodBody).
//
// Checks emitted (one per line, key=value):
//   body_size_ok       — serialized body is 12 bytes (1-byte tiny header + 11-byte code)
//   header_ok          — byte[0] == 0x2E (tiny header for codeSize=11)
//   ldstr_opcode_ok    — byte[1] == 0x72 (ldstr opcode)
//   ldstr_token_ok     — LE token bytes == 0x01, 0x00, 0x00, 0x70
//   call_opcode_ok     — byte[6] == 0x28 (call opcode)
//   call_token_ok      — LE token bytes == 0x01, 0x00, 0x00, 0x0A
//   ret_ok             — byte[11] == 0x2A (ret opcode)
//   branch_size_ok     — branch body is 9 bytes (1-byte tiny header + 8-byte code)
//   branch_header_ok   — branch header byte == 0x22 ((8<<2)|2)
//   branch_opcode_ok   — branch opcode byte == 0x38 (br long-form)
//   branch_offset_ok   — branch offset == 1 (forward by 1 byte past ldc.i4.1)

package Msil.SelfTestM2b

import Msil.Opcodes
import Msil.Kernel
import Std.Core
import Std.Collections

func check(label: in String, ok: in Bool): Unit {
  if ok { println(label + "=true") } else { println(label + "=false") }
}

func main(): Unit {
  // ── Test 1: ldstr / call / ret body ─────────────────────────────────────────
  // Expected bytes: 0x2E 0x72 0x01 0x00 0x00 0x70 0x28 0x01 0x00 0x00 0x0A 0x2A
  val b1 = newMethodBody()
  emitLdstr(b1, 0x70000001)
  emitCall(b1, 0x0A000001)
  emitRet(b1)

  val w1 = bufNew()
  serializeMethodBody(b1, w1)
  val bs1 = bufToList(w1)

  check("body_size_ok",    bufLen(w1) == 12)
  check("header_ok",       bs1[0] == 0x2E)
  check("ldstr_opcode_ok", bs1[1] == 0x72)
  // LE encoding of 0x70000001: byte order 0x01, 0x00, 0x00, 0x70
  check("ldstr_token_ok",  bs1[2] == 1 and bs1[3] == 0 and bs1[4] == 0 and bs1[5] == 112)
  check("call_opcode_ok",  bs1[6] == 0x28)
  // LE encoding of 0x0A000001: byte order 0x01, 0x00, 0x00, 0x0A
  check("call_token_ok",   bs1[7] == 1 and bs1[8] == 0 and bs1[9] == 0 and bs1[10] == 10)
  check("ret_ok",          bs1[11] == 0x2A)

  // ── Test 2: forward branch resolution ────────────────────────────────────────
  // Layout:
  //   PC=0  ldc.i4.0       (1 byte, OP_LDC_I4_0 = 0x16)
  //   PC=1  br L1          (5 bytes, OP_BR = 0x38 + 4-byte offset)
  //   PC=6  ldc.i4.1       (1 byte, unreachable)
  //   PC=7  L1: ret        (1 byte, OP_RET = 0x2A)
  // codeSize = 8, tiny header = (8<<2)|2 = 34 = 0x22
  // Branch offset = target(7) - nextPc(6) = 1
  val b2 = newMethodBody()
  val lbl = mbNewLabel(b2)
  emitLdc_I4_0(b2)
  emitBr(b2, lbl)
  emitLdc_I4_1(b2)
  mbMarkLabel(b2, lbl)
  emitRet(b2)

  val w2 = bufNew()
  serializeMethodBody(b2, w2)
  val bs2 = bufToList(w2)

  check("branch_size_ok",   bufLen(w2) == 9)
  check("branch_header_ok", bs2[0] == 0x22)
  check("branch_opcode_ok", bs2[2] == 0x38)
  check("branch_offset_ok", bs2[3] == 1 and bs2[4] == 0 and bs2[5] == 0 and bs2[6] == 0)
}
