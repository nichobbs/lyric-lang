//! lyric-ui/src/_kernel/guard_native.l - the failure guards on `--target
//! native`, the twin of `guard_managed.l` in the same package.
//!
//! Native has no unwinding (D-N-003): a panic in an effect ends the process,
//! so `guardedEffect` runs the effect directly, and a port is probed with a
//! listen that reports failure as a value.
//!
//! Internal: only Ui.Host and Ui.Host.Desktop should import this.
@cfg(feature = "native")
@io
package Ui.Kernel.Guard

import Std.Core
import Std.TcpHost as TcpHost

/// `run(effect)`.  A panic in it ends the process on this target.
pub func guardedEffect[E, Msg](run: in (E) -> Option[Msg], effect: in E): Option[Msg] {
  run(effect)
}

/// Whether a listener can bind `port` on `host` right now.
pub func canBindLoopback(host: in String, port: in Int): Bool {
  match TcpHost.hostListen(host, port) {
    case Ok(l) -> {
      TcpHost.hostCloseListener(l)
      true
    }
    case Err(_) -> false
  }
}
