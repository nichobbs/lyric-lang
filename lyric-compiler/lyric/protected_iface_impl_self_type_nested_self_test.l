//! `Self` NESTED inside a generic type argument (`List[Self]`) in an impl
//! method signature on a protected type — split out of
//! `protected_iface_impl_self_type_self_test.l` (#7585) so that file's
//! bare-`Self` cases can run on `--target native` too.
//!
//! `impl Iface for P` moves each impl method into `P` as a locked entry
//! (`protected_iface_impl_self_test.l`, #7457).  The elaborator's move copies
//! the signature unchanged, so the SAME erasure applies at any nesting
//! depth — `List[Self]` erases to `List<object>`/`List<Object>` on both the
//! interface slot and the moved entry, on dotnet and the JVM, with no
//! special-casing needed. Whole-value use (count, re-adding an element)
//! exercises the signature match this feature is actually about;
//! per-element field access through the erased list slot is a separate,
//! pre-existing narrowing gap shared with ordinary record impls
//! (`isSelfTypeExprMsil`/`isSelfTypeExprJvm` only recognise a bare (or
//! paren-wrapped) `Self`, not one nested inside a generic argument) and is
//! tracked in #7602.
//!
//! Runs on dotnet and the JVM only: `--target native` rejects `Self` nested
//! inside a generic type argument with a proper `N0006` diagnostic
//! (`Lyric.LlvmCodegen.nativeSelfShapeDiagnostics`, reported by
//! `Lyric.LlvmBridge` BEFORE codegen runs, #7585) rather than a silent
//! (and ABI-inconsistent) lowering or an internal panic — native's generic
//! types monomorphize per concrete type argument (`Lyric.Mono`), and there
//! is no call site to infer `T = Self` from at an interface declaration
//! the way a bare `Self` erases uniformly to a pointer-width `i8*`
//! (D-progress-1016). See `llvm_self_test_self_iface.l`'s last two tests
//! for the native-side `N0006` diagnostic coverage; native support for this
//! shape is tracked in #7603.
@test_module
package ProtectedIfaceImplSelfTypeNestedSelfTest

import Std.Core
import Std.Collections
import Std.Testing

pub interface Snapshot {
  func snapshot(): List[Self]
}

protected type Ledger {
  var n: Int = 0
}

impl Snapshot for Ledger {
  func snapshot(): List[Self] {
    val xs = newList()
    xs.add(self)
    xs
  }
}

test "a Self nested in a List return compiles and round-trips the element count" {
  val l = Ledger(n = 7)
  val xs = l.snapshot()
  assertTrue(xs.count == 1, "one element in the snapshot")
  val s: Snapshot = l
  val xs2 = s.snapshot()
  assertTrue(xs2.count == 1, "same result through the interface binding")
}
