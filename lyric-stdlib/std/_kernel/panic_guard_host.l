//! std/_kernel/panic_guard_host.l - run a callback with a `Bug` (panic)
//! caught at the call, on the targets that can unwind.
//!
//! `Std.JsonRpc` keeps a handler panic from killing its dispatch loop. That
//! needs `try`/`catch`, which `--target native` cannot lower (D-N-003: no
//! unwinding, a panic aborts the process). The guard is therefore a kernel
//! with a native twin (`_kernel_native/panic_guard_host.l`) that calls the
//! callback directly; this file serves dotnet and the JVM.
@io
package Std.PanicGuardHost

import Std.Core

/// A callback for `runCatchingBug`. It reports its outcome through its own
/// state, since the guard knows nothing of the caller's types.
pub interface BugGuarded {
  func invoke(): Unit
}

/// Run `g.invoke()`. True when it returned; false when it raised a `Bug`,
/// which is caught and discarded.
pub func runCatchingBug(g: in BugGuarded): Bool {
  try {
    g.invoke()
    true
  } catch Bug as b {
    false
  }
}
