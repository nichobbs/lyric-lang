//! `impl Iface for P` where `P` is a protected type (#7457).
//!
//! Before the fix this built on both targets and failed at run time: on
//! dotnet the class carried the InterfaceImpl row but none of the impl's
//! methods (`TypeLoadException`, or — when a protected member happened to
//! share the method's name — the impl body was silently dropped); on the JVM
//! the class never declared the interface (`ClassCastException`).  The impl
//! methods are now moved into the protected type as locked entries, so they
//! dispatch through the interface and run under the instance lock.  Runs on
//! dotnet, the JVM and native.  The contract cases (they need `try`/`catch`,
//! which native lacks) are in `protected_iface_impl_contracts_self_test.l`;
//! the concurrent (real-thread) cases in
//! `protected_exclusion_{dotnet,jvm}_self_test.l`.
@test_module
package ProtectedIfaceImplSelfTest

import Std.Core
import Std.Testing

pub interface Counter {
  func bump(by: in Int): Int
    requires: by > 0
  func current(): Int
}

pub interface Named {
  func label(): String
}

protected type Tally {
  var n: Int = 0
  var name: String = "tally"
  func doubled(): Int = n * 2
}

impl Counter for Tally {
  func bump(by: in Int): Int {
    n = n + by
    n
  }
  func current(): Int {
    self.n
  }
}

impl Named for Tally {
  func label(): String {
    name + ":" + toString(self.doubled())
  }
}

func bumpTwice(c: in Counter): Int {
  c.bump(2)
  c.bump(3)
}

func describe(x: in Named): String = x.label()

test "an interface method on a protected type dispatches through the interface" {
  val t = Tally()
  assertTrue(bumpTwice(t) == 5, "bump through an interface parameter")
  val c: Counter = t
  assertTrue(c.current() == 5, "current through an interface binding")
}

test "an impl method is callable on the concrete protected receiver" {
  val t = Tally()
  t.bump(4)
  assertTrue(t.current() == 4, "concrete receiver sees the write")
  assertTrue(t.doubled() == 8, "the type's own member sees the impl's write")
}

test "a protected type implements more than one interface" {
  val t = Tally(n = 3)
  assertTrue(describe(t) == "tally:6", "label calls a sibling member under the reentrant lock")
}
