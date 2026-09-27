//! `Self` in an impl method signature on a protected type (#7550).
//!
//! `impl Iface for P` moves each impl method into `P` as a locked entry
//! (`protected_iface_impl_self_test.l`, #7457).  When the interface method's
//! signature mentions `Self` — as a parameter, a return, or nested inside a
//! generic argument — the moved entry keeps `Self` UNSUBSTITUTED, so MSIL and
//! JVM erase it to `object`/`Object` exactly as they erase the interface
//! slot; no descriptor mismatch arises.  Runs on dotnet and the JVM only:
//! `--target native` cannot yet lower a `Self`-mentioning interface method at
//! all, for a record OR a protected type (`typeExprToNType`'s `TSelf` arm
//! panics "this type form is not yet supported for --target native" at
//! interface vtable-type registration) — a pre-existing, target-wide gap
//! this feature does not attempt to close (tracked as a follow-up).
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
  // The explicit `Merger` annotation (rather than an untyped `val f = ...`)
  // sidesteps a pre-existing, unrelated JVM binding quirk shared with
  // ordinary record impls: an untyped local bound from a `Self`-returning
  // call through an INTERFACE-typed receiver tracks as raw `Object`
  // codegen-internally (the type checker itself types the call result as
  // the interface, T0113 — `narrowSelfCallResult`'s own `sig.isIface`
  // early-out deliberately does not narrow further), so a later method
  // call on the untyped local's raw tracked type falls to the erased
  // Object auto-FFI guess instead of dispatching through the interface.
  val f: Merger = m.fresh()
  assertTrue(f.value() == 9, "fresh() through the interface returns a usable Acc")
}

test "a Self return narrows so the returned value's own members resolve, via the concrete receiver" {
  val a = Acc(n = 21)
  val f = a.fresh()
  assertTrue(f.n == 21, "fresh() via the concrete receiver exposes n directly")
}

// Nested `Self`: the elaborator's move copies the signature unchanged, so the
// SAME erasure applies at any nesting depth — `List[Self]` erases to
// `List<object>`/`List<Object>` on both the interface slot and the moved
// entry, on both targets, with no special-casing needed. Whole-value use
// (count, re-adding an element) exercises the signature match this feature
// is actually about; per-element field access through the erased list slot
// is a separate, pre-existing narrowing gap shared with ordinary record
// impls (`isSelfTypeExprMsil`/`isSelfTypeExprJvm` only recognise a bare
// (or paren-wrapped) `Self`, not one nested inside a generic argument) and
// is out of scope here.
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
