//! Testing.Conformance.Guard on `--target native`, the twin of
//! `guard_managed.l` in the same package.
//!
//! Native has no unwinding (D-N-003): a panic in a case ends the process, so
//! the case runs directly.
//!
//! Internal: only `Testing.Conformance` should import this.
@cfg(target = "native")
package Testing.Conformance.Guard

import Std.Core

/// `body()`.  A panic in it ends the process on this target.
pub func guardedCase(body: in () -> Unit): Option[String] {
  body()
  None
}
