//! std/_kernel_native/panic_guard_host.l - native twin of
//! `_kernel/panic_guard_host.l`.
//!
//! `--target native` has no unwinding (D-N-003): a panic aborts the process
//! before any caller could observe it, so the guard calls the callback
//! directly and a return always means it completed.
@io
package Std.PanicGuardHost

import Std.Core

/// A callback for `runCatchingBug`. It reports its outcome through its own
/// state, since the guard knows nothing of the caller's types.
pub interface BugGuarded {
  func invoke(): Unit
}

/// Run `g.invoke()`. Always true: on native a panic ends the process.
pub func runCatchingBug(g: in BugGuarded): Bool {
  g.invoke()
  true
}
