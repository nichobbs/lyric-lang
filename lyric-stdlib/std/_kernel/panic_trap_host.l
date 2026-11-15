//! std/_kernel/panic_trap_host.l - run a body and report whether it panicked,
//! on the targets that can unwind (dotnet and the JVM).
//!
//! `Std.Testing.assertPanics` needs `try`/`catch`, which `--target native`
//! cannot lower (D-N-003: no unwinding). The trap is therefore a kernel with a
//! native twin (`_kernel_native/panic_trap_host.l`, D608) that runs the body in
//! a forked child; this file serves dotnet and the JVM.
@io
package Std.PanicTrapHost

import Std.Core

/// How a trapped body ended. `PtFailed` is never produced here: it is the
/// native twin's report that the body ended the process some way other than
/// returning or panicking (a crash, `exit`), or that the trap could not start.
pub union PanicTry {
  case PtRan
  case PtPanicked(message: String)
  case PtFailed(message: String)
}

/// Run `fn()` and report how it ended. A `Bug` (a panic) is caught and its
/// message returned, with the runtime's `panic: ` envelope.
pub func trapPanic(fn: in () -> Unit): PanicTry {
  return try {
    fn()
    PtRan
  } catch Bug as b {
    PtPanicked(message = b.message)
  }
}
