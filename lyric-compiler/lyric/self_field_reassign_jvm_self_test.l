//! self_field_reassign_jvm_self_test.l — #6168: a bare self-field reassignment
//! inside an `impl` method (the implicit-receiver `selfFieldType` path in
//! `jvm/codegen/05_stmts.l`), whose RHS branches (an `if`-expression, or an
//! inlined `.slice()`/`.concat()` bounds check), followed by more code.
//!
//! Before the fix, `05_stmts.l`'s `selfFieldType` AssEq/compound arms pushed
//! `this` (aload_0) and then lowered the RHS with `this` still live on the
//! operand stack.  `assembleCodeWithFrames` assumes the operand stack is EMPTY
//! at every branch target, so a branching RHS produced an inconsistent
//! StackMapTable frame → `VerifyError: Inconsistent stackmap frames at branch
//! target` at class-load.  This is the implicit-self sibling of the
//! explicit-receiver `EMember` fix (#5936, covered by
//! `inout_field_self_reassign_self_test.l`).  Fixed by lowering the RHS against
//! an empty stack (push `this` only AFTER the RHS; read the current field into
//! a temp first for compound ops).
//!
//! JVM-ONLY.  The `--target dotnet` path is deliberately not exercised here:
//! bare self-field mutation inside an `impl` method is silently dropped on the
//! MSIL backend today (the writes never take effect — a separate, pre-existing
//! MSIL bug, filed independently), and `.slice()` on a self-field access is
//! also unsupported there.  The #6168 defect itself is JVM-specific (MSIL has
//! no StackMapTable), so a JVM-target regression pin is the correct and honest
//! coverage.  Wired into CI as a `--target jvm` step only.
@test_module
package Lyric.SelfFieldReassignJvmSelfTest

import Std.Core
import Std.Testing

record Acc {
  var total: Int
  var seen: Int
}

interface Stepper {
  func step(n: Int): Int
}

func classifyInt(n: in Int): Result[Int, String] {
  if n < 0 {
    Err(error = "neg")
  } else {
    Ok(value = 0)
  }
}

interface Bumper {
  func bump(n: Int): Int
}

impl Stepper for Acc {
  func step(n: Int): Int {
    // Bare self-field reassign (AssEq), RHS is a branching if-expression, then
    // more statements — the exact #6168 shape.
    total = if n > 0 { total + n } else { total }
    seen = seen + 1
    match classifyInt(n) {
      case Err(_) -> self.total
      case Ok(v) -> {
        total = total + v
        self.total
      }
    }
  }
}

impl Bumper for Acc {
  func bump(n: Int): Int {
    // COMPOUND self-field assign (`+=`) whose RHS is a branching if-expression
    // (#6186): the implicit-`this` compound arm must read the current field
    // into a temp, lower the branching RHS against an empty operand stack, then
    // combine and store — the compound analog of the #6168 AssEq fix.  `seen`'s
    // plain `+=` exercises the non-branching compound path in the same method.
    total += if n > 0 { n * 2 } else { 0 - 1 }
    seen += 1
    match classifyInt(n) {
      case Err(_) -> {
        total -= 5
        self.total
      }
      case Ok(_) -> self.total
    }
  }
}

test "bare self-field reassign with a branching RHS in an impl method (#6168)" {
  var a = Acc(total = 0, seen = 0)
  val r1 = a.step(5)
  assertEqualInt(r1, 5, "step(5) accumulates total to 5")
  val r2 = a.step(3)
  assertEqualInt(r2, 8, "step(3) accumulates total to 8")
  assertEqualInt(a.seen, 2, "seen incremented on each step, mutation persists")
}

test "compound self-field assign (+=) with a branching RHS in an impl method (#6186)" {
  var a = Acc(total = 10, seen = 0)
  // bump(4): total += (4>0 ? 4*2 : -1) = 10 + 8 = 18; seen += 1 = 1; Ok arm
  // returns total unchanged = 18.
  val r = a.bump(4)
  assertEqualInt(r, 18, "bump(4): compound += with a branching RHS -> 18")
  assertEqualInt(a.total, 18, "total field reflects the compound write")
  assertEqualInt(a.seen, 1, "seen reflects the plain compound increment")
  // bump(-2): total += (else -1) = 18 - 1 = 17; seen += 1 = 2; Err arm
  // (classifyInt(-2) = Err) runs total -= 5 = 12.
  val r2 = a.bump(0 - 2)
  assertEqualInt(r2, 12, "bump(-2): else-branch (-1) then Err-arm -= 5 -> 12")
  assertEqualInt(a.seen, 2, "seen incremented again, mutations persist")
}
