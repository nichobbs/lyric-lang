//! std/_kernel_native/panic_trap_host.l - native twin of
//! `_kernel/panic_trap_host.l` (D608).
//!
//! `--target native` has no unwinding (D-N-003), so a panic cannot be caught
//! where it is raised. The trap instead runs the body in a forked child:
//! `lyric_panic_trap_enter` forks like `fork(2)`, the child runs `fn()` with
//! its panics redirected down a pipe (`lyric_panic_msg`), and the parent reads
//! the verdict with `lyric_panic_trap_join`. The body's effects on memory are
//! therefore invisible to the caller; its effects outside the process (files,
//! sockets, output) are real. See D608 for what this cannot do.
@axiom("lyric_panic_trap_enter/join (lyric-rt) run the body in a forked child and report its exit faithfully")
@io
package Std.PanicTrapHost

import Std.Core

extern func trapEnter(): Long = "lyric_panic_trap_enter"

extern func trapChildDone(): Unit = "lyric_panic_trap_child_done"

extern func trapJoin(handle: Long): String = "lyric_panic_trap_join"

/// How a trapped body ended.
pub union PanicTry {
  case PtRan
  case PtPanicked(message: String)
  case PtFailed(message: String)
}

func enterFailure(code: Long): String {
  if code == -3i64 {
    "this target has no fork, so the body cannot be run apart from the test process (D608)"
  } else if code == -2i64 {
    "fork failed, so the body could not be run apart from the test process"
  } else {
    "pipe failed, so the body could not be run apart from the test process"
  }
}

/// Run `fn()` in a forked child and report how it ended. A panic's message
/// carries the managed targets' `panic: ` envelope.
pub func trapPanic(fn: in () -> Unit): PanicTry {
  val handle = trapEnter()
  if handle == 0i64 {
    fn()
    trapChildDone()
    return PtRan
  }
  if handle < 0i64 {
    return PtFailed(message = enterFailure(handle))
  }
  val verdict = trapJoin(handle)
  val rest = verdict.substring(1, verdict.length - 1)
  val kind = verdict.substring(0, 1)
  if kind == "P" {
    return PtPanicked(message = "panic: " + rest)
  }
  if kind == "F" {
    return PtFailed(message = rest)
  }
  return PtRan
}
