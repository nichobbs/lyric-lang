//! slice_byte_lambda_arg_self_test.l — runtime regression test for a
//! `slice[Byte]` index expression passed DIRECTLY as the argument to a
//! `(Byte) -> Bool`-typed parameter on MSIL (#5934).
//!
//! Before the fix, invoking a function-typed value (the uniform
//! `Func<object,…>` lambda ABI, #1877) boxed an inline `bytes[i]` argument
//! using its genuine collection-element static type (`MByte` /
//! `System.Byte` — kept by `sliceElemMsilCtx` for `byte[]`/`List<byte>` BCL
//! interop, #3472/#3473), while the callee's `Byte`-annotated parameter
//! always unboxes assuming the "scalar `Byte`" convention
//! (`typeExprToMsilCtx`'s `TRef("Byte") -> MInt` mapping) — an
//! `Int32`-boxed argument.  The mismatch threw
//! `System.InvalidCastException: Unable to cast object of type
//! 'System.Byte' to type 'System.Int32'` at the callee's `unbox.any
//! int32`.  Binding the indexed element to an explicit `Byte`-typed local
//! first avoided it, because the local's tracked type follows the same
//! scalar convention as the parameter, so both sides agreed.
//!
//! The fix normalizes an `MByte`-typed argument to the scalar `Byte`
//! convention (`MInt`) at the Func-invoke boxing site
//! (`funcAbiArgBoxTypeMsil` in `lyric-compiler/msil/codegen.l`) — both box
//! forms wrap the identical (non-negative) int32 CLI stack value a
//! `ldelem.u1`/`IList.get_Item`-loaded byte is stack-normalized to (ECMA-335
//! §III.1.1), so re-tagging the box as `Int32` matches what the callee
//! expects.
//!
//! Run by the native `lyric test` on BOTH targets (like
//! `bitwise_self_test.l` / `block_shadow_self_test.l`):
//!   lyric test --target dotnet lyric-compiler/lyric/slice_byte_lambda_arg_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/slice_byte_lambda_arg_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).  The JVM backend was
//! not observed to reproduce #5934 (its lambda-arg boxing does not carry
//! the MSIL-only `Byte`-scalar/`Byte`-collection-element split), so these
//! assertions serve as a JVM parity pin rather than a JVM regression fix.
@test_module
package Lyric.SliceByteLambdaArgSelfTest

import Std.Core
import Std.Testing

func isSpace(b: in Byte): Bool {
  b.toInt() == 32
}

// The #5934 repro shape: the `slice[Byte]` index expression is passed
// DIRECTLY as the call argument — never bound to a local first — so the
// argument's static type at the Func-invoke boxing site is whatever
// `bytes[i]`'s own EIndex codegen reports (the genuine `MByte`).
func findByteWhereInline(bytes: in slice[Byte], pred: in (Byte) -> Bool): Option[Int] {
  var i = 0
  while i < bytes.length {
    if pred(bytes[i]) {
      return Some(value = i)
    }
    i = i + 1
  }
  None
}

// Control case: the indexed element is bound to an explicit `Byte`-typed
// local BEFORE being passed to the function-typed parameter.  This is the
// documented pre-fix workaround — it must keep working after the fix too,
// pinning the exact shape of the bug (only the direct-inline-index-arg form
// was ever broken).
func findByteWhereViaLocal(bytes: in slice[Byte], pred: in (Byte) -> Bool): Option[Int] {
  var i = 0
  while i < bytes.length {
    val b: Byte = bytes[i]
    if pred(b) {
      return Some(value = i)
    }
    i = i + 1
  }
  None
}

test "slice[Byte] index expr passed directly to a (Byte) -> Bool lambda arg finds the match" {
  val xs: slice[Byte] = [65.toByte(), 32.toByte(), 66.toByte()]
  match findByteWhereInline(xs, { b: Byte -> isSpace(b) }) {
    case Some(i) -> assertEqualInt(i, 1, "inline index arg: space found at index 1")
    case None -> assertTrue(false, "inline index arg: expected to find the space byte")
  }
}

test "slice[Byte] index expr passed directly returns None when no element matches" {
  val xs: slice[Byte] = [65.toByte(), 66.toByte(), 67.toByte()]
  match findByteWhereInline(xs, { b: Byte -> isSpace(b) }) {
    case Some(_) -> assertTrue(false, "inline index arg: expected no match")
    case None -> assertTrue(true, "inline index arg: correctly found nothing")
  }
}

test "explicit Byte local bound from a slice[Byte] index still finds the match" {
  val xs: slice[Byte] = [65.toByte(), 32.toByte(), 66.toByte()]
  match findByteWhereViaLocal(xs, { b: Byte -> isSpace(b) }) {
    case Some(i) -> assertEqualInt(i, 1, "explicit local arg: space found at index 1")
    case None -> assertTrue(false, "explicit local arg: expected to find the space byte")
  }
}

test "inline index arg and explicit-local arg agree on the same input" {
  val xs: slice[Byte] = [1.toByte(), 2.toByte(), 32.toByte(), 3.toByte()]
  val inlineResult = findByteWhereInline(xs, { b: Byte -> isSpace(b) })
  val localResult = findByteWhereViaLocal(xs, { b: Byte -> isSpace(b) })
  match inlineResult {
    case Some(i1) -> {
      match localResult {
        case Some(i2) -> assertEqualInt(i1, i2, "both forms agree on the found index")
        case None -> assertTrue(false, "explicit-local form unexpectedly found nothing")
      }
    }
    case None -> assertTrue(false, "inline form unexpectedly found nothing")
  }
}
