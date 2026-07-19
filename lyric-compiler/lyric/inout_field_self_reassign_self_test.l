//! inout_field_self_reassign_self_test.l — runtime regression test for #5936:
//! on `--target jvm`, a function taking a record by `inout` that reassigns a
//! `slice[Byte]` field in place via `h.field = h.field.slice(...)` (reading
//! and reassigning the SAME field inline in one statement), followed by more
//! code (a `match`), emitted bytecode with an inconsistent stack-map frame:
//! `VerifyError: Inconsistent stackmap frames at branch target` at class-load.
//!
//! Root cause: `Jvm.Codegen`'s `EMember` field-assignment lowering
//! (`lyric-compiler/jvm/codegen/05_stmts.l`, `lowerAssignExpr`) pushed the
//! receiver (`h`) onto the JVM operand stack, then lowered the RHS expression
//! with the receiver still live on the stack. When the RHS reads the same
//! field being assigned via an inlined call whose lowering contains an
//! internal conditional branch (`.slice()`/`.concat()`'s bounds check,
//! `lowerSliceSliceJvm`/`lowerSliceConcatJvm` in `04_calls.l`), the branch
//! target's StackMapTable frame was computed by `assembleCodeWithFrames`
//! (`bytecode.l`) under the documented invariant that the operand stack is
//! EMPTY at every branch target — but the receiver was still on the stack,
//! so the computed frame disagreed with the actual runtime stack shape.
//! Binding the slice/concat result to a local first (`val r = h.buf.slice(...);
//! h.buf = r`) sidestepped the bug because then the RHS is evaluated with an
//! empty ambient stack, matching the invariant.
//!
//! Fix: the receiver (and, for compound assignment, the current field value)
//! is spilled to a temp local slot and RELOADED after the RHS is lowered,
//! rather than kept live on the operand stack across it — so RHS lowering
//! always starts from an empty operand stack, regardless of what internal
//! branches it contains.
//!
//! Run by the native `lyric test` on BOTH targets (like `block_shadow_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/inout_field_self_reassign_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_field_self_reassign_self_test.l
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! in-process through the self-hosted `Msil.Bridge` / `Jvm.Bridge`, then
//! asserts every embedded value.  Imports only `Std.*` (no
//! `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.InoutFieldSelfReassignSelfTest

import Std.Core
import Std.Testing

record Holder {
  buf: slice[Byte]
  count: Int
}

func classify(bytes: in slice[Byte]): Result[Int, String] {
  if bytes.length == 0 {
    Err(error = "empty")
  } else {
    Ok(value = bytes.length)
  }
}

// #5936's exact repro shape: `h.buf = h.buf.slice(n, h.buf.length)` reads and
// reassigns the SAME field inline, followed by a `match` — the shape whose
// JVM lowering hit the `VerifyError`.
func consumeAndClassify(h: inout Holder, n: in Int): Unit {
  val taken = h.buf.slice(0, n)
  h.buf = h.buf.slice(n, h.buf.length)
  match classify(taken) {
    case Err(_) -> {
      h.count = 0 - 1
    }
    case Ok(value) -> {
      h.count = h.count + value
    }
  }
}

// The `.concat()` variant the issue also reported: `state.buf = state.buf.concat(...)`.
func appendAndClassify(h: inout Holder, more: in slice[Byte]): Unit {
  h.buf = h.buf.concat(more)
  match classify(h.buf) {
    case Err(_) -> {
      h.count = 0 - 1
    }
    case Ok(value) -> {
      h.count = h.count + value
    }
  }
}

// Control: the explicit-local workaround form (`val r = …; h.buf = r`) that
// sidestepped the bug pre-fix — pinned so a regression in the general path
// doesn't silently rely on this shape alone.
func consumeAndClassifyViaLocal(h: inout Holder, n: in Int): Unit {
  val taken = h.buf.slice(0, n)
  val rest = h.buf.slice(n, h.buf.length)
  h.buf = rest
  match classify(taken) {
    case Err(_) -> {
      h.count = 0 - 1
    }
    case Ok(value) -> {
      h.count = h.count + value
    }
  }
}

// #6186: the COMPOUND-assignment (`+=`/`-=`) arm of the same `lowerAssignExpr`
// rewrite — untested by the AssEq cases above.  A compound assign whose RHS is
// a branching if-expression is the exact compound-arm analog of #5936: the arm
// reads the current field value, then must lower the branching RHS against an
// empty operand stack (both the field value and the receiver spilled to temps)
// before combining, or the branch target's stack-map frame desyncs.
func accumulateCompound(h: inout Holder, n: in Int): Unit {
  h.count += if n > 0 { n * 2 } else { 0 - 1 }
  match classify(h.buf) {
    case Err(_) -> {
      h.count -= 3
    }
    case Ok(value) -> {
      h.count += value
    }
  }
}

test "inline self-reassign slice() then match mutates count and buf (#5936)" {
  var h = Holder(buf = [65.toByte(), 66.toByte(), 67.toByte(), 68.toByte()], count = 0)
  consumeAndClassify(h, 2)
  assertEqualInt(h.count, 2, "count after classify(taken)")
  assertEqualInt(h.buf.length, 2, "remaining buf length")
  assertEqualInt(h.buf[0].toInt(), 67, "remaining buf[0] is 'C'")
  assertEqualInt(h.buf[1].toInt(), 68, "remaining buf[1] is 'D'")
}

test "inline self-reassign concat() then match mutates count and buf (#5936)" {
  var h = Holder(buf = [1.toByte(), 2.toByte()], count = 0)
  val more: slice[Byte] = [3.toByte(), 4.toByte(), 5.toByte()]
  appendAndClassify(h, more)
  assertEqualInt(h.count, 5, "count after classify(h.buf) on the appended buf")
  assertEqualInt(h.buf.length, 5, "buf length after concat")
  assertEqualInt(h.buf[0].toInt(), 1, "buf[0] unchanged")
  assertEqualInt(h.buf[4].toInt(), 5, "buf[4] is the appended tail")
}

test "explicit-local slice() then match mutates count and buf (control)" {
  var h = Holder(buf = [65.toByte(), 66.toByte(), 67.toByte(), 68.toByte()], count = 0)
  consumeAndClassifyViaLocal(h, 2)
  assertEqualInt(h.count, 2, "count after classify(taken)")
  assertEqualInt(h.buf.length, 2, "remaining buf length")
  assertEqualInt(h.buf[0].toInt(), 67, "remaining buf[0] is 'C'")
  assertEqualInt(h.buf[1].toInt(), 68, "remaining buf[1] is 'D'")
}

// Empty-taken variant: exercises the `Err` match arm (bytes.length == 0) so
// both arms of the inline-self-reassign-then-match shape run under the fix.
test "inline self-reassign slice() with an empty taken slice hits the Err arm" {
  var h = Holder(buf = [9.toByte(), 10.toByte()], count = 7)
  consumeAndClassify(h, 0)
  assertEqualInt(h.count, 0 - 1, "count set by the Err arm")
  assertEqualInt(h.buf.length, 2, "remaining buf unchanged")
}

test "compound-assign (+=) with a branching RHS on an inout field (#6186)" {
  var h = Holder(buf = [7.toByte(), 8.toByte()], count = 10)
  // count = 10 + (n>0 ? n*2 : -1) = 10 + 8 = 18; classify(buf, len 2) = Ok(2)
  // -> count += 2 = 20.
  accumulateCompound(h, 4)
  assertEqualInt(h.count, 20, "compound += with a branching RHS, then Ok-arm += value")
  // Negative-n path takes the else-branch (-1) and the count stays > 0 so the
  // Ok arm still runs: count = 5 + (-1) + 2 = 6.
  var h2 = Holder(buf = [7.toByte(), 8.toByte()], count = 5)
  accumulateCompound(h2, 0 - 3)
  assertEqualInt(h2.count, 6, "compound += else-branch (-1) then Ok-arm += value")
}
