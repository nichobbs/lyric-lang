//! Jobs.Kernel.Guard on `--target native`, the twin of `guard_managed.l` in the
//! same package.
//!
//! Native has no unwinding (D-N-003): a panic in a handler ends the process,
//! so the attempt runs directly.
//!
//! Internal: only `Jobs` should import this.
@cfg(target = "native")
package Jobs.Kernel.Guard

import Std.Core

/// `attempt()`.  A panic in it ends the process on this target.
pub func guardedAttempt(attempt: in () -> Result[String, String]): Result[String, String] {
  attempt()
}
