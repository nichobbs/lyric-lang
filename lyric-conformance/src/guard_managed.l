//! Testing.Conformance.Guard, managed targets (`dotnet`, `jvm`) — one
//! conformance case with a panic in it caught.  The native twin
//! (`guard_native.l`, same package) has no unwinding to catch.
//!
//! Internal: only `Testing.Conformance` should import this.
@cfg(not(target = "native"))
package Testing.Conformance.Guard

import Std.Core

/// `body()`: `None` when it returned, the panic's message when it panicked.
pub func guardedCase(body: in () -> Unit): Option[String] {
  try {
    body()
    None
  } catch Bug as b {
    Some(value = b.message)
  }
}
