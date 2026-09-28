//! `Self` in an impl method signature on a protected type (#7550).
//!
//! `impl Iface for P` moves each impl method into `P` as a locked entry
//! (`protected_iface_impl_self_test.l`, #7457).  When the interface method's
//! signature mentions `Self` — as a bare parameter or return — the moved
//! entry keeps `Self` UNSUBSTITUTED, so MSIL and JVM erase it to
//! `object`/`Object` exactly as they erase the interface slot; no descriptor
//! mismatch arises.
//!
//! Runs on dotnet, the JVM, AND `--target native` (#7585): native erases a
//! bare `Self` in the interface's own vtable slot to a pointer-width `i8*`
//! (D-progress-1016), and substitutes `Self` to the concrete protected type in the
//! moved entry's own signature (`registerProtectedMember`) before it ever
//! reaches `typeToN`, mirroring the record-impl substitution
//! (`substSelfInFn`/`collectImplMethods`) that already worked pre-#7585.
//! `Lyric.LlvmCodegen.llvm_self_test_self_iface.l` covers the same shapes
//! directly against the native backend (including an ASan-clean ARC check);
//! this file's own native run is the end-to-end proof through the full
//! `Lyric.Pipeline` (contract elaborator + weaver) that
//! `llvm_self_test_self_iface.l`'s narrower harness bypasses.
//!
//! `Self` NESTED inside a generic type argument (`List[Self]`) is a
//! SEPARATE, still-unsupported native shape (`protected_iface_impl_self_type_nested_self_test.l`,
//! dotnet/JVM only) — native's generic types monomorphize per concrete type
//! argument, and there is no call site to infer `T = Self` from at an
//! interface declaration, so that shape stays a proper `N0006` diagnostic
//! reported by `Lyric.LlvmBridge` before codegen runs rather than a silent
//! lowering or an internal panic; splitting it into its own file keeps
//! THIS file's bare-`Self` cases runnable on native.
@test_module
package ProtectedIfaceImplSelfTypeSelfTest

import Std.Core
import Std.Collections
import Std.Testing

pub interface Merger {
  func merge(other: in Self): Int
  func fresh(): Self
  func value(): Int
}

protected type Acc {
  var n: Int = 0
}

impl Merger for Acc {
  func merge(other: in Self): Int {
    n = n + other.n
    n
  }
  func fresh(): Self {
    Acc(n = n)
  }
  func value(): Int {
    self.n
  }
}

test "a Self parameter reads the other instance's own field, via an interface binding" {
  val a = Acc(n = 3)
  val b = Acc(n = 4)
  val m: Merger = a
  assertTrue(m.merge(b) == 7, "merge through the interface reads other's n")
}

test "a Self parameter reads the other instance's own field, via the concrete receiver" {
  val a = Acc(n = 10)
  val b = Acc(n = 5)
  assertTrue(a.merge(b) == 15, "merge via the concrete receiver")
}

test "a Self return narrows so the returned value's own members resolve, via an interface binding" {
  val a = Acc(n = 9)
  val m: Merger = a
  // Untyped local (#7586): a `Self`-returning call through an
  // INTERFACE-typed receiver types as the interface itself (T0113), and
  // `narrowSelfCallResult` now narrows the codegen-internal tracked type
  // (and checkcasts) to the interface class on JVM too, so an unannotated
  // `val` resolves a later method call through the interface rather than
  // falling to the erased Object auto-FFI guess.
  val f = m.fresh()
  assertTrue(f.value() == 9, "fresh() through the interface returns a usable Acc")
}

test "a Self return narrows so the returned value's own members resolve, via the concrete receiver" {
  val a = Acc(n = 21)
  val f = a.fresh()
  assertTrue(f.n == 21, "fresh() via the concrete receiver exposes n directly")
}
