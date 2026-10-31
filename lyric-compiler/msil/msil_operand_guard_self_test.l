//! msil_operand_guard_self_test.l - codegen-level regression test for the
//! T0120 operand guards of the MSIL operator lowering (#8344).
//!
//! An operator never guesses an operand's type: an operand the lowering only
//! knows as `object` has no static numeric type, and `add`/`sub`/`mul`/`div`/
//! `rem` or an ordering comparison on object references is unverifiable IL
//! that crashes or yields garbage.  No source program reaches a guard today:
//! the type checker records a type for every operand (a function-value call
//! result, the original #8283 trigger, is now typed) and rejects an extern
//! `System.Object` operand with T0030.  The guards are the backstop for a
//! future typing gap, so this test feeds synthetic erased operand types
//! straight into the two guard functions every arithmetic (`+ - * / %`, unary
//! `-`) and ordering (`< > <= >=`) lowering site calls, and asserts that a
//! positioned T0120 error is produced - and that a fully typed operand pair,
//! or an erased operand the comparison reconciles by unboxing, is not
//! reported.
//!
//! The JVM path needs no twin: `Jvm.Codegen`'s `BAdd` panics at compile time
//! for two `Object` operands (#6398), and the other operators resolve a
//! numeric or string operation from the known side.
//!
//! Run in CI via native `lyric test` (imports `Msil.Codegen`, resolved by
//! linking the already-compiled compiler DLLs as restored deps):
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_operand_guard_self_test.l
@test_module
package Msil.OperandGuardSelfTest

import Msil.Codegen
import Msil.Lowering
import Lyric.Lexer
import Lyric.Parser
import Std.Core
import Std.Collections
import Std.Testing

func spanAt(line: in Int, col: in Int): Span {
  val p = Position(offset = line * 100 + col, line = line, column = col)
  Span(startPos = p, endPos = p)
}

func nameExpr(name: in String, line: in Int, col: in Int): Expr {
  val sp = spanAt(line, col)
  Expr(kind = EPath(path = ModulePath(segments = [name], span = sp)), span = sp)
}

func freshCtx(): CodegenCtx {
  newCodegenCtx("Msil.OperandGuardSelfTest", newList(), newList(), 1, 0)
}

func t0120Count(cctx: in CodegenCtx): Int {
  var n = 0
  var i = 0
  while i < cctx.diagnostics.count {
    if cctx.diagnostics[i].code == "T0120" {
      n = n + 1
    }
    i = i + 1
  }
  n
}

test "arithmetic: two erased operands report T0120 on the left operand" {
  val cctx = freshCtx()
  val l = nameExpr("a", 3, 5)
  val r = nameExpr("b", 3, 9)
  requireTypedArithOperandsMsil(cctx, "+", l, r, MObject, MObject)
  assertEqualInt(t0120Count(cctx), 1, "one diagnostic")
  assertEqualInt(cctx.diagnostics[0].span.startPos.line, 3, "line")
  assertEqualInt(cctx.diagnostics[0].span.startPos.column, 5, "left column")
}

test "arithmetic: an erased right operand beside a Long reports on the right" {
  val cctx = freshCtx()
  val l = nameExpr("a", 4, 1)
  val r = nameExpr("b", 4, 7)
  requireTypedArithOperandsMsil(cctx, "+", l, r, MLong, MObject)
  assertEqualInt(t0120Count(cctx), 1, "one diagnostic")
  assertEqualInt(cctx.diagnostics[0].span.startPos.column, 7, "right column")
}

test "arithmetic: every operator reports an erased operand" {
  val ops = ["+", "-", "*", "/", "%"]
  var i = 0
  while i < ops.count {
    val cctx = freshCtx()
    val e = nameExpr("x", 1, 1)
    requireTypedArithOperandsMsil(cctx, ops[i], e, e, MObject, MInt)
    assertEqualInt(t0120Count(cctx), 1, "operator " + ops[i])
    i = i + 1
  }
}

test "arithmetic: unary minus passes the operand as both sides" {
  val cctx = freshCtx()
  val e = nameExpr("x", 6, 2)
  requireTypedArithOperandsMsil(cctx, "-", e, e, MObject, MObject)
  assertEqualInt(t0120Count(cctx), 1, "one diagnostic")
}

test "arithmetic: an extern System.Object class counts as erased" {
  val cctx = freshCtx()
  val e = nameExpr("x", 2, 2)
  requireTypedArithOperandsMsil(cctx, "*", e, e, MClass(className = "System.Object"), MInt)
  assertEqualInt(t0120Count(cctx), 1, "System.Object")
}

test "arithmetic: typed operands are not reported" {
  val cctx = freshCtx()
  val e = nameExpr("x", 1, 1)
  requireTypedArithOperandsMsil(cctx, "+", e, e, MInt, MInt)
  requireTypedArithOperandsMsil(cctx, "+", e, e, MLong, MInt)
  requireTypedArithOperandsMsil(cctx, "-", e, e, MDouble, MDouble)
  assertEqualInt(t0120Count(cctx), 0, "no diagnostics")
}

test "comparison: two erased operands report T0120" {
  val cctx = freshCtx()
  val l = nameExpr("a", 8, 3)
  val r = nameExpr("b", 8, 8)
  requireTypedCompareOperandsMsil(cctx, "<", l, r, MObject, MObject)
  assertEqualInt(t0120Count(cctx), 1, "one diagnostic")
  assertEqualInt(cctx.diagnostics[0].span.startPos.column, 3, "left column")
}

test "comparison: an erased operand against a reference type reports T0120" {
  val cctx = freshCtx()
  val l = nameExpr("a", 9, 1)
  val r = nameExpr("b", 9, 6)
  requireTypedCompareOperandsMsil(cctx, ">=", l, r, MString, MObject)
  assertEqualInt(t0120Count(cctx), 1, "one diagnostic")
  assertEqualInt(cctx.diagnostics[0].span.startPos.column, 6, "right column")
}

test "comparison: an erased operand against a value type is unboxed, not reported" {
  val cctx = freshCtx()
  val e = nameExpr("x", 1, 1)
  requireTypedCompareOperandsMsil(cctx, "<=", e, e, MObject, MInt)
  requireTypedCompareOperandsMsil(cctx, ">", e, e, MLong, MObject)
  assertEqualInt(t0120Count(cctx), 0, "no diagnostics")
}

test "comparison: typed operands are not reported" {
  val cctx = freshCtx()
  val e = nameExpr("x", 1, 1)
  requireTypedCompareOperandsMsil(cctx, "<", e, e, MString, MString)
  requireTypedCompareOperandsMsil(cctx, "<", e, e, MInt, MInt)
  assertEqualInt(t0120Count(cctx), 0, "no diagnostics")
}
