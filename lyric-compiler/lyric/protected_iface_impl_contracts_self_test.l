//! Contracts on `impl Iface for P` where `P` is a protected type (#7457).
//!
//! The impl's methods become locked entries of `P`, so the interface's own
//! `requires:` still guards them and `P`'s invariant is re-checked after each
//! one returns.  Runs on dotnet and the JVM; dispatch and locking are covered
//! by `protected_iface_impl_self_test.l`.
@test_module
package ProtectedIfaceImplContractsSelfTest

import Std.Core
import Std.Testing

pub interface Counter {
  func bump(by: in Int): Int
    requires: by > 0
  func current(): Int
}

protected type Tally {
  var n: Int = 0
  invariant: n < 100
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

test "the interface's requires: clause guards the moved method" {
  val t = Tally()
  var caught = false
  try {
    t.bump(0)
  } catch Bug as b {
    caught = true
  }
  assertTrue(caught, "bump(0) violates requires: by > 0")
  assertTrue(t.current() == 0, "the rejected call changed nothing")
}

test "the protected type's invariant is re-checked after an impl method" {
  val t = Tally(n = 98)
  var caught = false
  try {
    t.bump(5)
  } catch Bug as b {
    caught = true
  }
  assertTrue(caught, "bump past 100 breaks invariant: n < 100")
}
