//! Jobs.Kernel.Guard, managed targets (`dotnet`, `jvm`) — one attempt of a job
//! handler with a panic in it caught.  The native twin (`guard_native.l`, same
//! package) has no unwinding to catch.
//!
//! Internal: only `Jobs` should import this.
@cfg(not(target = "native"))
package Jobs.Kernel.Guard

import Std.Core

/// `attempt()`, with a panic in it reported as a failed attempt.
pub func guardedAttempt(attempt: in () -> Result[String, String]): Result[String, String] {
  try {
    attempt()
  } catch Bug as b {
    Err("handler panicked: " + b.message)
  }
}
