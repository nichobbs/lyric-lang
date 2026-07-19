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

impl Stepper for Acc {
  func step(n: Int): Int {
    // Bare self-field reassign, RHS is a branching if-expression, then more
    // statements — the exact #6168 shape.
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

test "bare self-field reassign with a branching RHS in an impl method (#6168)" {
  var a = Acc(total = 0, seen = 0)
  val r1 = a.step(5)
  assertEqualInt(r1, 5, "step(5) accumulates total to 5")
  val r2 = a.step(3)
  assertEqualInt(r2, 8, "step(3) accumulates total to 8")
  assertEqualInt(a.seen, 2, "seen incremented on each step, mutation persists")
}

test "compound self-field assign with a branching sibling in an impl method (#6168)" {
  var a = Acc(total = 10, seen = 0)
  // step(2): total = if 2>0 { 10+2 } else {10} = 12; seen=1; Ok -> total=12; returns 12.
  val r = a.step(2)
  assertEqualInt(r, 12, "step(2) from total=10 yields 12")
  assertEqualInt(a.total, 12, "total field reflects the accumulated writes")
  assertEqualInt(a.seen, 1, "seen field reflects the compound-style increment")
}
