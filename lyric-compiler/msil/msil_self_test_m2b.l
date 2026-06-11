//! msil_self_test_m2b.l — Stage M2b self-test for the typed CIL instruction IR.
//!
//! Exercises Msil.Opcodes: the Insn union, MethodBody accumulator, and the
//! two-pass assembler (serializeMethodBody).
//!
//! Run in CI via native `lyric test` (D-progress-474 / #66), linking the
//! already-compiled compiler DLLs as restored deps:
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_self_test_m2b.l
//!
//! `Msil.Opcodes` exports module-level `pub val OP_*` constants, so this
//! test links the self-hosted-emitted compiler DLLs staged under
//! `<libdir>/selfhosted` (#3086) — the F#-emitted stage-1 metadata omits
//! `pub val` decls.
@test_module
package Msil.SelfTestM2b

import Msil.Opcodes
import Msil.Kernel
import Std.Core
import Std.Collections
import Std.Testing

test "ldstr / call / ret body serializes byte-exact" {
  // Expected bytes: 0x2E 0x72 0x01 0x00 0x00 0x70 0x28 0x01 0x00 0x00 0x0A 0x2A
  val b1 = newMethodBody()
  emitLdstr(b1, 0x70000001)
  emitCall(b1, 0x0A000001)
  emitRet(b1)

  val w1 = bufNew()
  serializeMethodBody(b1, w1)
  val bs1 = bufToList(w1)

  // Serialized body is 12 bytes (1-byte tiny header + 11-byte code).
  assertEqualInt(bufLen(w1), 12, "body size")
  // Tiny header for codeSize=11.
  assertTrue(bs1[0] == 0x2E, "tiny header")
  assertTrue(bs1[1] == 0x72, "ldstr opcode")
  // LE encoding of 0x70000001: byte order 0x01, 0x00, 0x00, 0x70.
  assertTrue(bs1[2] == 1 and bs1[3] == 0 and bs1[4] == 0 and bs1[5] == 112, "ldstr token LE bytes")
  assertTrue(bs1[6] == 0x28, "call opcode")
  // LE encoding of 0x0A000001: byte order 0x01, 0x00, 0x00, 0x0A.
  assertTrue(bs1[7] == 1 and bs1[8] == 0 and bs1[9] == 0 and bs1[10] == 10, "call token LE bytes")
  assertTrue(bs1[11] == 0x2A, "ret opcode")
}

test "forward branch resolves to the marked label" {
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

  assertEqualInt(bufLen(w2), 9, "branch body size")
  assertTrue(bs2[0] == 0x22, "branch tiny header")
  assertTrue(bs2[2] == 0x38, "br long-form opcode")
  assertTrue(bs2[3] == 1 and bs2[4] == 0 and bs2[5] == 0 and bs2[6] == 0, "branch offset LE bytes")
}
